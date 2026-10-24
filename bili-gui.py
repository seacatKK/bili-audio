#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bili-gui —— B 站直播「弹幕窗口 + 音频播放」图形应用

界面：上方是直播间实时弹幕（可滚动、自动滚到底），下方输入框可直接发送弹幕；
顶部工具条可切换直播间、开关声音（复用同目录的 bili-audio.ps1）。

技术选型（本机实测结论，别改回去）：
  * 用 Python + tkinter：本机 Python 3.12 带 tkinter 8.6，且 Python 走自带 OpenSSL，
    能直连 B 站 HTTPS；而本机 PowerShell/.NET 走 schannel 访问 HTTPS 会报
    SEC_E_NO_CREDENTIALS，ffmpeg 也不行 —— 所以 GUI 自己处理网络，不依赖 Node/PowerShell。
  * 弹幕用 HTTP 轮询（dM/gethistory），因为 B 站弹幕长连接在这台机器上被风控掐断
    （getDanmuInfo 恒 -352、comet 连上即 1006；详见 diag/ 里的复现脚本）。延迟约 1~2 秒。
  * 发送走 msg/send + csrf=bili_jct（已验证可用，与长连接被掐是两套通道）。
  * 音频复用 bili-audio.ps1 子进程：退出时一并清理，避免留孤儿进程。

用法：
    py -3 bili-gui.py [房间号|直播间地址|别名] [--interval 2] [--volume 40]
自检（无头/自动化验证用）：
    py -3 bili-gui.py 6 --selftest 8            显示 8 秒后把窗口内容与状态打印出来并退出
    py -3 bili-gui.py 6 --selftest-send 1       走 GUI 的发送代码路径真发一条并打印结果
"""
import argparse
import ctypes
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

import tkinter as tk
from tkinter import font as tkfont
from tkinter import messagebox, ttk

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
HISTORY_SHOWN = 5          # 启动时先显示的最近弹幕条数
CREATE_NO_WINDOW = 0x08000000


class JobGuard(object):
    """把音频子进程放进 Windows Job Object，并设置 KILL_ON_JOB_CLOSE：
    句柄一关，内核连带杀掉整棵进程树（powershell + ffplay + streamlink + python）。

    为什么不用 taskkill：本机沙箱里 tasklist/taskkill 会被「拒绝访问」（实测），
    依赖它会导致关闭窗口后音频进程残留、继续出声。Job 对象只操作自己的子进程，不会被拒。
    """

    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
    JobObjectExtendedLimitInformation = 9

    def __init__(self):
        self.handle = None
        self.k32 = None
        if os.name != "nt":
            return
        try:
            class IO_COUNTERS(ctypes.Structure):
                _fields_ = [("ReadOperationCount", ctypes.c_ulonglong),
                            ("WriteOperationCount", ctypes.c_ulonglong),
                            ("OtherOperationCount", ctypes.c_ulonglong),
                            ("ReadTransferCount", ctypes.c_ulonglong),
                            ("WriteTransferCount", ctypes.c_ulonglong),
                            ("OtherTransferCount", ctypes.c_ulonglong)]

            class JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
                _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64),
                            ("PerJobUserTimeLimit", ctypes.c_int64),
                            ("LimitFlags", ctypes.c_uint32),
                            ("MinimumWorkingSetSize", ctypes.c_size_t),
                            ("MaximumWorkingSetSize", ctypes.c_size_t),
                            ("ActiveProcessLimit", ctypes.c_uint32),
                            ("Affinity", ctypes.c_void_p),
                            ("PriorityClass", ctypes.c_uint32),
                            ("SchedulingClass", ctypes.c_uint32)]

            class JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
                _fields_ = [("BasicLimitInformation", JOBOBJECT_BASIC_LIMIT_INFORMATION),
                            ("IoInfo", IO_COUNTERS),
                            ("ProcessMemoryLimit", ctypes.c_size_t),
                            ("JobMemoryLimit", ctypes.c_size_t),
                            ("PeakProcessMemoryUsed", ctypes.c_size_t),
                            ("PeakJobMemoryUsed", ctypes.c_size_t)]

            self._ext_info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION
            k32 = ctypes.WinDLL("kernel32", use_last_error=True)
            k32.CreateJobObjectW.restype = ctypes.c_void_p
            handle = k32.CreateJobObjectW(None, None)
            if not handle:
                return
            info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
            info.BasicLimitInformation.LimitFlags = self.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            ok = k32.SetInformationJobObject(ctypes.c_void_p(handle),
                                             self.JobObjectExtendedLimitInformation,
                                             ctypes.byref(info), ctypes.sizeof(info))
            if not ok:
                k32.CloseHandle(ctypes.c_void_p(handle))
                return
            self.handle = handle
            self.k32 = k32
        except Exception:
            self.handle = None

    def assign(self, pid):
        if not self.handle:
            return False
        try:
            PROCESS_SET_QUOTA, PROCESS_TERMINATE = 0x0100, 0x0001
            h = self.k32.OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, False, int(pid))
            if not h:
                return False
            ok = self.k32.AssignProcessToJobObject(ctypes.c_void_p(self.handle), ctypes.c_void_p(h))
            self.k32.CloseHandle(ctypes.c_void_p(h))
            return bool(ok)
        except Exception:
            return False

    def close(self):
        if self.handle:
            try:
                self.k32.CloseHandle(ctypes.c_void_p(self.handle))
            except Exception:
                pass
            self.handle = None


# ------------------------------------------------------------------ 基础工具

def load_config():
    """读取本目录 config.json；缺失时回退旧版 rooms.json。失败返回空 dict。"""
    for name in ("config.json", "rooms.json"):
        path = os.path.join(TOOL_DIR, name)
        if os.path.exists(path):
            try:
                with open(path, encoding="utf-8") as fh:
                    data = json.load(fh)
                if isinstance(data, dict):
                    return data
            except Exception as exc:
                print("[warn] %s 解析失败: %s" % (name, exc))
    return {}


def load_cookies(config=None):
    """cookie 来源优先级：config.json 的 bilibili 节 > 旧版 cookies.txt > 环境变量 > 本机 streamlink 配置。

    config.json 里这样填（留空表示不用）：
        {"bilibili": {"sessdata": "你的SESSDATA", "bili_jct": "你的bili_jct"}}
    只看弹幕通常只需 sessdata（或本机 streamlink 已登录）；发弹幕额外需要 bili_jct。
    """
    jar = {}

    def add(raw):
        # 先读到的不被覆盖：这样来源顺序就等于优先级顺序
        for part in str(raw).split(";"):
            if "=" in part:
                k, v = part.split("=", 1)
                k, v = k.strip(), v.strip()
                if k and v and k not in jar:
                    jar[k] = v

    config = config or load_config()
    bili = (config or {}).get("bilibili") or {}
    if bili.get("sessdata"):
        jar["SESSDATA"] = str(bili["sessdata"])
    if bili.get("buvid3"):
        jar["buvid3"] = str(bili["buvid3"])
    if bili.get("bili_jct"):
        jar["bili_jct"] = str(bili["bili_jct"])
    local = os.path.join(TOOL_DIR, "cookies.txt")
    if os.path.exists(local):
        with open(local, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                t = line.strip()
                if t and not t.startswith("#"):
                    add(t)
    if os.environ.get("SESSDATA"):
        jar.setdefault("SESSDATA", os.environ["SESSDATA"])
    if os.environ.get("BILI_JCT"):
        jar.setdefault("bili_jct", os.environ["BILI_JCT"])
    # 兜底：本机 streamlink 配置（对已经登录 streamlink 的用户免配置）
    cfg = os.path.join(os.environ.get("APPDATA", ""), "streamlink", "config")
    if os.path.exists(cfg):
        with open(cfg, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                m = re.match(r"^\s*http-cookie\s*=\s*(.+)$", line, re.I)
                if m:
                    add(m.group(1))
    local = os.path.join(TOOL_DIR, "cookies.txt")
    if os.path.exists(local):
        with open(local, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                t = line.strip()
                if t and not t.startswith("#"):
                    add(t)
    return jar


def resolve_room(arg):
    """支持 房间号 / 直播间地址 / config.json 里的别名，返回 (房间号, 说明)。"""
    if re.match(r"^https?://", arg, re.I):
        m = re.search(r"(\d+)", arg)
        return (m.group(1), arg) if m else (None, None)
    if re.match(r"^\d+$", arg):
        return (arg, arg)
    rooms = (load_config() or {}).get("rooms", {}) or {}
    if rooms:
        try:
            entry = rooms.get(arg)
            if entry:
                url = entry if isinstance(entry, str) else entry.get("url", "")
                m = re.search(r"(\d+)", str(url))
                if m:
                    return (m.group(1), f"%s -> {url}" % arg)
        except Exception:
            pass
    return (None, None)


class Api(object):
    """B 站直播接口（Python 自带 OpenSSL，直连 HTTPS）。"""

    def __init__(self, jar):
        self.jar = jar

    def headers(self, room):
        return {
            "User-Agent": UA,
            "Referer": "https://live.bilibili.com/%s" % room,
            "Origin": "https://live.bilibili.com",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Cookie": "; ".join("%s=%s" % (k, v) for k, v in self.jar.items()),
        }

    def _call(self, url, room, data=None):
        headers = self.headers(room)
        body = None
        if data is not None:
            body = urllib.parse.urlencode(data).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        req = urllib.request.Request(url, data=body, headers=headers)
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def room_init(self, room):
        """短号必须解析成真实 room_id（如房间 6 -> 7734200），顺带取开播状态。"""
        try:
            j = self._call("https://api.live.bilibili.com/room/v1/Room/room_init?id=%s" % room, room)
            data = j.get("data") or {}
            return str(data.get("room_id") or room), data.get("live_status")
        except Exception:
            return str(room), None

    def real_room_id(self, room):
        return self.room_init(room)[0]

    def recent(self, room):
        url = ("https://api.live.bilibili.com/xlive/web-room/v1/dM/gethistory"
               "?roomid=%s&room_type=0" % room)
        j = self._call(url, room)
        if j.get("code") != 0:
            raise RuntimeError("接口 code=%s msg=%s" % (j.get("code"), j.get("message")))
        data = j.get("data") or {}
        return (data.get("room") or []), (data.get("admin") or [])

    def send(self, room, text):
        if not self.can_send():
            raise RuntimeError("缺少发弹幕所需的 cookie：请在 config.json 的 bilibili.bili_jct 里填入你的值（见 README「配置」）")
        body = {
            "bubble": "0", "msg": text, "color": "16777215", "mode": "1", "fontsize": "25",
            "rnd": str(int(time.time())), "roomid": str(room),
            "csrf": self.jar.get("bili_jct", ""), "csrf_token": self.jar.get("bili_jct", ""),
        }
        j = self._call("https://api.live.bilibili.com/msg/send", room, data=body)
        if j.get("code") != 0:
            hint = {-101: "（未登录/SESSDATA 失效）", -111: "（csrf 校验失败，bili_jct 不对）",
                    10030: "（内容被拒或频率限制）", -403: "（被禁言或权限不足）",
                    -352: "（撞上风控）"}.get(j.get("code"), "")
            raise RuntimeError("发送失败 code=%s msg=%s %s" % (j.get("code"), j.get("message"), hint))
        return j

    def can_send(self):
        return bool(self.jar.get("bili_jct") and self.jar.get("SESSDATA"))


def dm_key(m):
    return m.get("id_str") or "%s-%s-%s" % (m.get("uid"), m.get("rnd"), m.get("text"))


def dm_badges(m):
    out = []
    if m.get("isadmin"):
        out.append("房管")
    g = m.get("guard_level") or 0
    if g == 1:
        out.append("总督")
    elif g == 2:
        out.append("提督")
    elif g == 3:
        out.append("舰长")
    medal = m.get("medal")
    if isinstance(medal, list) and len(medal) > 1 and medal[1]:
        out.append("%s%s" % (medal[1], medal[0] if len(medal) else ""))
    return out


def dm_name_color(m):
    c = (m.get("uname_color") or "").strip()
    return c if re.match(r"^#[0-9A-Fa-f]{6}$", c) else ""


def parse_ts(s):
    """把接口里的 "2026-09-27 18:23:24" 解析成本地时间戳；解析不了返回 None。"""
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})", str(s or ""))
    if not m:
        return None
    try:
        return time.mktime((int(m.group(1)), int(m.group(2)), int(m.group(3)),
                            int(m.group(4)), int(m.group(5)), int(m.group(6)), 0, 0, -1))
    except Exception:
        return None


def ts_age_seconds(m):
    """消息年龄（秒）；无时间戳返回 None。"""
    ts = parse_ts(m.get("timeline"))
    if ts is None:
        return None
    return max(0.0, time.time() - ts)


def fmt_age(sec):
    if sec is None:
        return "?"
    if sec < 90:
        return "%.0f 秒" % sec
    if sec < 5400:
        return "%.1f 分钟" % (sec / 60.0)
    return "%.1f 小时" % (sec / 3600.0)


# ------------------------------------------------------------------ 主窗口

class App(object):
    def __init__(self, root, room_arg, interval=2.0, volume=40, selftest=0,
                 selftest_audio=False, selftest_ui_send=None, max_age=120.0, config=None):
        self.root = root
        self.interval = max(0.5, float(interval))
        self.volume = volume
        self.selftest = selftest
        self.config = config or {}
        self.jar = load_cookies(self.config)
        self.api = Api(self.jar)
        self.queue = queue.Queue()
        self.stop_flag = threading.Event()
        self.seen = set()
        self.seen_order = []
        self.count_all = 0
        self.count_shown = 0
        self.polls = 0
        self.errors = 0
        self.audio_proc = None
        self.job = JobGuard()
        self.job_assigned = False
        # 时效门槛：轮询接口返回的是「最近 N 条」滚动窗口，跨度可达数分钟甚至更久，
        # 首次启动若原样显示，就会把凌晨/几小时前的旧弹幕当成"当前弹幕"（用户实测报过）。
        # 因此只显示年龄 ≤ max_age 秒的消息，并将其余计入 stale_skipped 在状态栏说明。
        self.max_age = max(0.0, float(max_age))
        self.stale_skipped = 0
        self.stale_oldest = None
        self.live_status = None
        self.first_poll = True
        self.room_arg = room_arg
        self.room = None
        self.real_room = None

        self._build_ui()
        self._connect(room_arg)
        self.poll_thread = threading.Thread(target=self._poll_loop, daemon=True)
        self.poll_thread.start()
        self.root.after(150, self._drain)
        if selftest:
            self.root.after(int(selftest * 1000), self._selftest_finish)
        if selftest_audio:
            self.root.after(1500, self._selftest_audio_start)
        if selftest_ui_send:
            self._ui_send_text = selftest_ui_send
            self.root.after(1500, self._selftest_ui_send_start)
            self.root.after(9000, self._selftest_ui_send_check)

    # ---------------- 界面 ----------------
    def _build_ui(self):
        self.root.title("B 站直播弹幕 + 音频")
        self.root.geometry("760x560")
        self.root.minsize(520, 360)

        ui_font = self._pick_font(10)
        self.f_ui = ui_font
        self.f_dm = self._pick_font(10, mono=False)
        self.f_meta = self._pick_font(9)

        # 用 grid 布局：row1 弹幕区带 weight 吸收剩余空间，row2 输入行 / row3 状态栏
        # 一定拿得到自己的高度。之前用 pack + Text 默认 24 行高度，把窗口占满后
        # 输入行与状态栏被挤成 0 高度、完全不可见（实测踩过，控件树 dump 定位到）。
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(1, weight=1)

        bar = ttk.Frame(self.root, padding=(8, 6, 8, 2))
        bar.grid(row=0, column=0, sticky="ew")

        ttk.Label(bar, text="直播间", font=ui_font).pack(side="left")
        self.room_var = tk.StringVar(value=self.room_arg)
        ent_room = ttk.Entry(bar, textvariable=self.room_var, width=22, font=ui_font)
        ent_room.pack(side="left", padx=(6, 4))
        ent_room.bind("<Return>", lambda e: self._connect(self.room_var.get()))
        ttk.Button(bar, text="连接", command=lambda: self._connect(self.room_var.get())).pack(side="left")

        self.autoscroll = tk.BooleanVar(value=True)
        ttk.Checkbutton(bar, text="自动滚动", variable=self.autoscroll).pack(side="left", padx=(12, 0))
        ttk.Button(bar, text="清屏", command=self.clear).pack(side="left", padx=(8, 0))

        self.audio_btn = ttk.Button(bar, text="开声音", command=self.toggle_audio)
        self.audio_btn.pack(side="right")

        # 弹幕区（上方）
        mid = ttk.Frame(self.root, padding=(8, 4, 8, 4))
        mid.grid(row=1, column=0, sticky="nsew")
        self.txt = tk.Text(mid, height=6, wrap="word", state="disabled", font=self.f_dm,
                           background="#1e1f22", foreground="#e6e6e6",
                           insertbackground="#e6e6e6", relief="flat", padx=10, pady=8)
        sb = ttk.Scrollbar(mid, command=self.txt.yview)
        self.txt.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        self.txt.pack(side="left", fill="both", expand=True)
        self.txt.tag_configure("new", foreground="#ffffff")
        self.txt.tag_configure("history", foreground="#9a9a9a")
        self.txt.tag_configure("admin", foreground="#ffd479")
        self.txt.tag_configure("sys", foreground="#7ec8ff")
        self.txt.tag_configure("badge", foreground="#8fb4ff")
        self.txt.tag_configure("name", foreground="#7ee787")
        self.txt.tag_configure("time", foreground="#6e7681")

        # 输入区（下方）
        bot = ttk.Frame(self.root, padding=(8, 2, 8, 6))
        bot.grid(row=2, column=0, sticky="ew")
        self.entry = ttk.Entry(bot, font=ui_font)
        self.entry.pack(side="left", fill="x", expand=True, ipady=3)
        self.entry.bind("<Return>", lambda e: self.on_send())
        self.send_btn = ttk.Button(bot, text="发送", command=self.on_send)
        self.send_btn.pack(side="left", padx=(6, 0))

        # 状态栏
        self.status = tk.StringVar(value="启动中…")
        ttk.Label(self.root, textvariable=self.status, font=self.f_meta,
                  anchor="w", padding=(10, 2, 10, 6)).grid(row=3, column=0, sticky="ew")

        self.root.protocol("WM_DELETE_WINDOW", self.on_close)
        if not self.api.can_send():
            self.entry.configure(state="disabled")
            self.send_btn.configure(state="disabled")

    def _pick_font(self, size, mono=False):
        try:
            fams = set(tkfont.families(self.root))
            for name in (["Consolas"] if mono else ["Microsoft YaHei UI", "Microsoft YaHei"]):
                if name in fams:
                    return (name, size)
        except Exception:
            pass
        return ("TkDefaultFont", size)

    # ---------------- 房间连接 ----------------
    def _connect(self, arg):
        arg = (arg or "").strip()
        room, desc = resolve_room(arg)
        if not room:
            messagebox.showerror("无法识别的直播间", "既不是房间号/地址，也不是 config.json 里的别名：\n%s" % arg)
            return
        real, live = self.api.room_init(room)
        self.room = str(room)
        self.real_room = str(real)
        self.live_status = live
        self.room_arg = arg
        self.seen.clear()
        self.seen_order = []
        self.first_poll = True
        self.polls = self.errors = 0
        self.stale_skipped = 0
        self.stale_oldest = None
        self.clear()
        tip = "（短号已解析为真实 %s）" % real if str(real) != str(room) else ""
        self._append("sys", "已连接直播间 %s%s%s" % (
            real, tip, "" if live == 1 else ("（当前未开播）" if live is not None else "")))
        self._append("sys", "只显示 %.0f 秒内的弹幕（轮询接口的“最近 N 条”里可能混有更早的消息，"
                            "过期的不当成当前弹幕；可用 --max-age 调整）" % self.max_age)
        if desc and desc != room:
            self._append("sys", "来源：%s" % desc)
        self._set_status()

    def _set_status(self, extra=""):
        ability = "可发送" if self.api.can_send() else "不可发送（缺 bili_jct）"
        if self.live_status == 1:
            live = "直播中"
        elif self.live_status is None:
            live = "开播状态未知"
        else:
            live = "未开播"
        stale = ""
        if self.stale_skipped:
            stale = " | 已跳过 %d 条过期弹幕（最旧 %s，门槛 %.0f 秒）" % (
                self.stale_skipped, fmt_age(self.stale_oldest), self.max_age)
        msg = "房间 %s（%s） | 轮询 %.1fs | 收到 %d 条 / 显示 %d 条 | 轮询 %d 次 / 失败 %d 次 | %s%s" % (
            self.real_room or "-", live, self.interval, self.count_all, self.count_shown,
            self.polls, self.errors, ability, stale)
        if extra:
            msg += " | " + extra
        self.status.set(msg)

    # ---------------- 弹幕显示 ----------------
    def _append(self, kind, text, name=None, name_color="", badges=None, ts=""):
        self.txt.configure(state="normal")
        if ts:
            self.txt.insert("end", "%s " % ts, ("time",))
        if badges:
            self.txt.insert("end", "[%s] " % "/".join(badges),
                            ("badge",) if kind != "admin" else ("admin",))
        if name:
            tag = ("name",)
            if name_color:
                t = "c_%s" % name_color.lstrip("#")
                self.txt.tag_configure(t, foreground=name_color)
                tag = (t,)
            self.txt.insert("end", "%s: " % name, tag)
        tag = {"new": ("new",), "history": ("history",),
               "admin": ("admin",), "sys": ("sys",)}.get(kind, ("new",))
        self.txt.insert("end", text + "\n", tag)
        self.txt.configure(state="disabled")
        if self.autoscroll.get():
            self.txt.see("end")
        self.count_shown += 1

    def _drain(self):
        try:
            while True:
                item = self.queue.get_nowait()
                kind = item[0]
                if kind == "dm":
                    _, m, is_new = item
                    ts = ""
                    tl = str(m.get("timeline") or "")
                    mobj = re.search(r"(\d{2}:\d{2}:\d{2})", tl)
                    if mobj:
                        ts = mobj.group(1)
                    self._append("new" if is_new else "history", str(m.get("text") or ""),
                                 name=str(m.get("nickname") or "?"),
                                 name_color=dm_name_color(m), badges=dm_badges(m), ts=ts)
                elif kind == "admin":
                    _, a = item
                    ts = ""
                    mobj = re.search(r"(\d{2}:\d{2}:\d{2})", str(a.get("timeline") or ""))
                    if mobj:
                        ts = mobj.group(1)
                    self._append("admin", str(a.get("text") or ""),
                                 name=str(a.get("nickname") or "房管"), ts=ts)
                elif kind == "sys":
                    self._append("sys", item[1])
                elif kind == "status":
                    self._set_status(item[1] if len(item) > 1 else "")
                elif kind == "send_ok":
                    self._append("sys", "已发送：%s" % item[1])
                elif kind == "send_err":
                    self._append("sys", "发送失败：%s" % item[1])
                    messagebox.showerror("发送失败", item[1])
        except queue.Empty:
            pass
        finally:
            if not self.stop_flag.is_set():
                self.root.after(150, self._drain)

    def clear(self):
        self.txt.configure(state="normal")
        self.txt.delete("1.0", "end")
        self.txt.configure(state="disabled")
        self.count_shown = 0

    # ---------------- 轮询线程 ----------------
    def _poll_loop(self):
        def unseen_of(lst):
            out = []
            for m in lst:
                self.count_all += 1
                k = dm_key(m)
                if k in self.seen:
                    continue
                self.seen.add(k)
                self.seen_order.append(k)
                out.append(m)
            if len(self.seen_order) > 4000:
                for k2 in self.seen_order[:2000]:
                    self.seen.discard(k2)
                del self.seen_order[:2000]
            return out

        def split_by_age(lst):
            """按时效门槛分流：返回 (可显示, 过期年龄列表)；没有时间戳的保守显示。"""
            ok, bad = [], []
            for m in lst:
                age = ts_age_seconds(m)
                if self.max_age > 0 and age is not None and age > self.max_age:
                    bad.append(age)
                else:
                    ok.append(m)
            return ok, bad

        while not self.stop_flag.is_set():
            try:
                room = self.real_room
                msgs, admins = self.api.recent(room)
                self.polls += 1
                if self.polls % 15 == 0:          # 约每 30 秒刷新一次开播状态
                    _, self.live_status = self.api.room_init(room)

                if self.first_poll:
                    # 首次轮询只处理弹幕列表；房管消息留到下一次轮询走正常分支——
                    # 否则它们会被"首次"这次静默标记为已见、从此永不显示（自己复查代码发现的缺陷）。
                    new_msgs, bad = split_by_age(unseen_of(msgs))
                else:
                    new_msgs, bad1 = split_by_age(unseen_of(msgs))
                    new_admins, bad2 = split_by_age(unseen_of(admins))
                    bad = bad1 + bad2
                if bad:
                    self.stale_skipped += len(bad)
                    worst = max(bad)
                    self.stale_oldest = worst if self.stale_oldest is None else max(self.stale_oldest, worst)

                if self.first_poll:
                    # 首次只显示「仍然新鲜」的最近几条：轮询接口的“最近 N 条”可能混有几分钟甚至几小时前的
                    # 消息，原样显示会被误认为当前弹幕（用户实测报过这个 BUG）。
                    for m in new_msgs[-HISTORY_SHOWN:]:
                        self.queue.put(("dm", m, False))
                    if not new_msgs and bad:
                        self.queue.put(("sys", "启动时没有新鲜弹幕：已跳过 %d 条过期弹幕（最旧 %s）——"
                                               "这些不是当前弹幕" % (len(bad), fmt_age(max(bad)))))
                    self.first_poll = False
                else:
                    for m in new_msgs:
                        self.queue.put(("dm", m, True))
                    for a in new_admins:
                        self.queue.put(("admin", a))
                self.queue.put(("status", ""))
            except Exception as exc:
                self.errors += 1
                self.queue.put(("sys", "轮询失败：%s" % exc))
                self.queue.put(("status", ""))
                time.sleep(min(30.0, self.interval * max(1, self.errors)))
                continue
            time.sleep(self.interval)

    # ---------------- 发送 ----------------
    def on_send(self):
        text = self.entry.get().strip()
        if not text:
            return
        if not self.api.can_send():
            messagebox.showwarning("无法发送", "缺少 bili_jct：请在 config.json 的 bilibili.bili_jct 里填入你的值")
            return
        self.entry.delete(0, "end")
        threading.Thread(target=self._send_worker, args=(text,), daemon=True).start()

    def _send_worker(self, text):
        try:
            self.api.send(self.real_room, text)
            self.queue.put(("send_ok", text))
        except Exception as exc:
            self.queue.put(("send_err", str(exc)))

    # ---------------- 音频 ----------------
    def toggle_audio(self):
        if self.audio_proc and self.audio_proc.poll() is None:
            self._kill_audio()
            return
        ps1 = os.path.join(TOOL_DIR, "bili-audio.ps1")
        if not os.path.exists(ps1):
            messagebox.showerror("找不到音频脚本", ps1)
            return
        args = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1,
                self.room_arg, "-Volume", str(self.volume)]
        try:
            self.audio_proc = subprocess.Popen(args, creationflags=CREATE_NO_WINDOW,
                                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as exc:
            messagebox.showerror("音频启动失败", str(exc))
            return
        self.job_assigned = self.job.assign(self.audio_proc.pid)
        self.audio_btn.configure(text="关声音")
        self._append("sys", "音频已启动（音量 %s，进程清理方式：%s）；日志见 logs\\bili-audio-*.log"
                     % (self.volume, "Job 对象" if self.job_assigned else "taskkill 兜底"))

    def _kill_audio(self):
        if self.audio_proc and self.audio_proc.poll() is None:
            # 首选：关闭 Job 句柄 -> 内核连带杀掉整棵进程树（powershell + ffplay + streamlink + python）
            if self.job.handle:
                self.job.close()
            # 兜底：taskkill（本机沙箱会「拒绝访问」，所以只作兜底）+ 直接终止子进程
            try:
                subprocess.run(["taskkill", "/F", "/T", "/PID", str(self.audio_proc.pid)],
                               creationflags=CREATE_NO_WINDOW, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=10)
            except Exception:
                pass
            try:
                if self.audio_proc.poll() is None:
                    self.audio_proc.terminate()
            except Exception:
                pass
            self.job = JobGuard()   # 为下一次「开声音」准备新 Job
            self.job_assigned = False
        self.audio_proc = None
        self.audio_btn.configure(text="开声音")
        self._append("sys", "音频已停止")

    # ---------------- 退出 / 自检 ----------------
    def on_close(self):
        self.stop_flag.set()
        self._kill_audio()
        try:
            self.root.destroy()
        except Exception:
            pass

    def _selftest_finish(self):
        """把窗口真实内容与状态打印到 stdout，便于自动化验证（看不见屏幕也能验证）。"""
        lines = self.txt.get("1.0", "end").strip().splitlines()
        print("SELFTEST mapped=%s size=%dx%d" % (self.root.winfo_ismapped(),
                                                 self.root.winfo_width(), self.root.winfo_height()))
        print("SELFTEST room=%s polls=%d errors=%d received=%d rendered=%d can_send=%s"
              % (self.real_room, self.polls, self.errors, self.count_all, len(lines),
                 self.api.can_send()))
        print("SELFTEST widgets: entry_state=%s send_btn=%s" % (self.entry.cget("state"), self.send_btn.cget("text")))
        print("SELFTEST freshness max_age=%.0fs 跳过过期=%d 最旧=%s live_status=%s" % (
            self.max_age, self.stale_skipped, fmt_age(self.stale_oldest), self.live_status))
        print("SELFTEST last_lines:")
        for line in lines[-6:]:
            print("    " + line)
        # 结构性证据：不靠肉眼看截图，用控件真实坐标证明「弹幕在上、输入在下」。
        # 必须用 update()：update_idletasks() 不会映射控件，测出来全是 1x1（实测踩过）。
        self.root.update()
        geo = lambda w: (w.winfo_x(), w.winfo_y(), w.winfo_width(), w.winfo_height())
        print("SELFTEST geometry 弹幕区=%s 输入框=%s 发送按钮=%s" % (
            geo(self.txt), geo(self.entry), geo(self.send_btn)))
        # 用屏幕绝对坐标比较：winfo_y() 是相对各自父容器的，直接比较会得出错误结论（实测踩过）
        print("SELFTEST layout_check 弹幕区在输入框上方=%s 弹幕区面积更大=%s (弹幕区rooty=%d 输入框rooty=%d)" % (
            self.txt.winfo_rooty() < self.entry.winfo_rooty(),
            self.txt.winfo_height() * self.txt.winfo_width() > self.entry.winfo_height() * self.entry.winfo_width(),
            self.txt.winfo_rooty(), self.entry.winfo_rooty()))
        # 控件树全量 dump：定位「谁没被映射/尺寸为 0」这类问题，不靠猜
        def walk(w, depth=0):
            for c in w.winfo_children():
                print("    tree %s%s mapped=%s geo=%s" % (
                    "  " * depth, c.winfo_class(), c.winfo_ismapped(), c.winfo_geometry()))
                if depth < 2:
                    walk(c, depth + 1)
        print("SELFTEST tree(root=%s mapped=%s):" % (self.root.winfo_class(), self.root.winfo_ismapped()))
        walk(self.root)
        self.on_close()

    def _selftest_ui_send_start(self):
        print("SELFTEST_UI 模拟在输入框打字并点「发送」: %r" % self._ui_send_text)
        self.entry.delete(0, "end")
        self.entry.insert(0, self._ui_send_text)
        self.on_send()

    def _selftest_ui_send_check(self):
        body = self.txt.get("1.0", "end")
        ok = ("已发送：" + self._ui_send_text) in body
        err = "发送失败" in body
        print("SELFTEST_UI 结果 出现已发送提示=%s 出现失败提示=%s" % (ok, err))
        last = body.strip().splitlines()[-1] if body.strip() else "(空)"
        print("SELFTEST_UI 末行: %s" % last)
        self.on_close()

    def _selftest_audio_start(self):
        print("SELFTEST_AUDIO 调用 GUI 的「开声音」按钮逻辑")
        self.toggle_audio()
        self.root.after(13000, self._selftest_audio_check)

    def _last_audio_start_line(self):
        """从音频工具日志里取最近一条“已启动: streamlink pid=… -> ffplay pid=…”作为播放证据。
        不用 tasklist：本机沙箱对进程枚举会「拒绝访问」（实测），会得出假阴性。"""
        import glob
        hits = []
        for f in sorted(glob.glob(os.path.join(TOOL_DIR, "logs", "bili-audio-*.log"))):
            try:
                with open(f, encoding="utf-8", errors="ignore") as fh:
                    for line in fh:
                        if "ffplay pid=" in line:
                            hits.append(line.strip())
            except Exception:
                continue
        return hits[-1] if hits else ""

    def _selftest_audio_check(self):
        proc = self.audio_proc
        alive = bool(proc and proc.poll() is None)
        print("SELFTEST_AUDIO 启动后 child_alive=%s job_assigned=%s" % (alive, self.job_assigned))
        print("SELFTEST_AUDIO 音频日志证据: %s" % (self._last_audio_start_line() or "(未找到)"))
        self._kill_audio()
        time.sleep(2.5)
        print("SELFTEST_AUDIO 关闭后 child_alive=%s（应为 False；ffplay/streamlink 是孙进程，由 Job 对象连带清理）"
              % bool(proc and proc.poll() is None))
        self.on_close()


def selftest_send(room_arg, text):
    """走 GUI 用的同一套发送代码路径，真发一条并打印结果。"""
    jar = load_cookies()
    api = Api(jar)
    room, _ = resolve_room(room_arg)
    if not room:
        print("SELFTEST_SEND 无法识别直播间: %s" % room_arg)
        return 2
    real = api.real_room_id(room)
    print("SELFTEST_SEND room=%s can_send=%s text=%r" % (real, api.can_send(), text))
    try:
        j = api.send(real, text)
        print("SELFTEST_SEND ok code=%s data=%s" % (j.get("code"), json.dumps(j.get("data"), ensure_ascii=False)[:200]))
        return 0
    except Exception as exc:
        print("SELFTEST_SEND failed: %s" % exc)
        return 1


def main():
    cfg = load_config()
    defaults = (cfg or {}).get("defaults") or {}
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("room", nargs="?", default=None,
                    help="房间号 / 直播间地址 / config.json 里的别名（留空则用 defaults.room）")
    ap.add_argument("--interval", type=float, default=float(defaults.get("interval") or 2.0))
    ap.add_argument("--max-age", type=float, default=float(defaults.get("max_age") or 120.0),
                    help="只显示年龄不超过该秒数的弹幕（默认 120；0 = 不过滤）")
    ap.add_argument("--volume", type=int, default=int(defaults.get("volume") or 40))
    ap.add_argument("--selftest", type=float, default=0)
    ap.add_argument("--selftest-audio", action="store_true")
    ap.add_argument("--selftest-ui-send", default=None)
    ap.add_argument("--selftest-send", default=None)
    args = ap.parse_args()

    room_arg = (args.room or str(defaults.get("room") or "")).strip()
    if not room_arg:
        print("用法: py -3 bili-gui.py <房间号|直播间地址|别名> [选项]")
        print("提示：也可以在 config.json 的 defaults.room 里配置默认直播间。")
        sys.exit(2)
    args.room = room_arg

    if args.selftest_send is not None:
        sys.exit(selftest_send(args.room, args.selftest_send))

    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        pass

    root = tk.Tk()
    app = App(root, args.room, interval=args.interval, volume=args.volume,
              selftest=args.selftest, selftest_audio=args.selftest_audio,
              selftest_ui_send=args.selftest_ui_send, max_age=args.max_age, config=cfg)
    root.mainloop()
    sys.exit(0)


if __name__ == "__main__":
    main()
