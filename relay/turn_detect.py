"""Python mirror of the phone's turn detection (VoiceLogic.NoiseFloor + TurnEndpointer in
ios/Hermes/Voice/VoiceLogic.swift and GeminiLive.swift), so the thresholds can be tried on real or
synthetic audio (relay/probe_vad.py --phone / --client) and unit-tested here. Keep the numbers in
sync with the Swift.

Two modes, chosen by the phone per session:
- server: Gemini's own VAD ends turns; this only backs it up (audioStreamEnd after quiet).
- client (noisy rooms): Gemini's VAD is off; this decides activityStart / activityEnd. Babble and PA
  announcements keep server VAD "in speech" forever (the airport bug), so Otto ends turns itself.
"""
from __future__ import annotations

import math

# A room louder than this at the start of a session (or for NOISY_HOLD s later) is "noisy".
NOISY_FLOOR = -45.0
NOISY_HOLD = 3.0


class NoiseFloor:
    CAL_SECONDS = 0.5
    WINDOW = 4.0          # seconds of levels the percentile tracker looks at
    SUSTAINED = 2.5       # "voice" on this long without a 0.3 s gap is the room, not a person
    PERCENTILE = 0.2
    TAU = 1.5             # seconds: how fast the floor moves toward that percentile
    TAU_DOWN = 0.2        # quieter room: follow quickly (0.1 per 21 ms buffer)
    TAU_UP = 2.1          # louder room: creep up, never on voice (0.01 per 21 ms buffer)
    MAX_FLOOR = -20.0

    def __init__(self) -> None:
        self.floor = -60.0
        self.calibrated = False
        self.samples: list[float] = []
        self.cal_time = 0.0
        self.window: list[tuple[float, float]] = []
        self.run = 0.0
        self.gap = 0.0

    def threshold(self, playing: bool = False) -> float:
        return max(self.floor + (16 if playing else 10), -44 if playing else -52)

    def is_voice(self, db: float, playing: bool = False) -> bool:
        return self.calibrated and db >= self.threshold(playing)

    def observe(self, db: float, playing: bool = False, dur: float = 1024 / 48000) -> bool:
        db = max(-100.0, min(0.0, db))
        if not self.calibrated:
            self.samples.append(db)
            self.cal_time += dur
            if self.cal_time >= self.CAL_SECONDS - 1e-6 and len(self.samples) >= 5:
                s = sorted(self.samples)
                self.floor, self.calibrated, self.samples = min(self.MAX_FLOOR, s[len(s) // 2]), True, []
            return False
        voice = self.is_voice(db, playing)
        if db < self.floor:
            self.floor += (db - self.floor) * (1 - math.exp(-dur / self.TAU_DOWN))
        elif not voice and not playing:
            self.floor += (db - self.floor) * (1 - math.exp(-dur / self.TAU_UP))
        if not playing:
            self.window.append((db, dur))
            total = sum(d for _, d in self.window)
            while self.window and total - self.window[0][1] >= self.WINDOW:
                total -= self.window.pop(0)[1]
            if voice:
                self.run += dur
                self.gap = 0.0
            else:
                self.gap += dur
                if self.gap >= 0.3:
                    self.run = 0.0
            if self.run >= self.SUSTAINED:
                levels = sorted(v for v, _ in self.window)
                p = levels[int(len(levels) * self.PERCENTILE)]
                if p > self.floor:
                    self.floor += (p - self.floor) * (1 - math.exp(-dur / self.TAU))
        self.floor = max(-90.0, min(self.MAX_FLOOR, self.floor))
        return voice


class TurnDetector:
    MIN_SPEECH = 0.3
    SPEECH_OVER_FLOOR = 12.0
    QUIET_OVER_FLOOR = 8.0
    BELOW_SPEECH = 15.0
    QUIET_TO_END = 1.5          # server mode backup (Gemini usually ends first)
    CLIENT_QUIET_TO_END = 1.5   # client mode: we are the only end-of-turn
    # Client mode bands. The floor follows the room's quiet moments and `room_mid` is the room's
    # median level (babble sits a few dB over its floor). A turn opens on >= 0.3 s (within 0.6 s) of
    # chunks over floor+8 / mid+6; a 0.2 s word over floor+6 / mid+4 and within 8 dB of his own level
    # keeps it open; it is quiet once back under floor+4 / mid+2, or 8+ dB under his level (far-field
    # talkers). 1.5 s of quiet ends it; 25 s ends it anyway.
    CLIENT_ONSET = 8.0
    CLIENT_TALK = 6.0
    CLIENT_QUIET = 4.0
    CLIENT_BELOW_SPEECH = 12.0
    CLIENT_NEAR = 8.0
    CLIENT_WORD = 0.2   # talking this long resets the quiet timer
    CLIENT_ONSET_OVER_MID = 6.0
    CLIENT_TALK_OVER_MID = 4.0
    CLIENT_QUIET_OVER_MID = 2.0
    ONSET_WINDOW = 0.6
    ONSET_SPEECH = 0.3
    MAX_TURN = 25.0

    def __init__(self) -> None:
        self.room = NoiseFloor()
        self.speech = 0.0
        self.level: float | None = None
        self.quiet = 0.0
        self.active = False       # client mode: an activity is open
        self.turn_time = 0.0      # seconds since this turn's first speech
        self.recent: list[tuple[bool, float, float]] = []
        self.room_mid: float | None = None  # the room's median level, learned between turns
        self.talk_run = 0.0

    @property
    def heard_speech(self) -> bool:
        return self.speech >= self.MIN_SPEECH

    def _classify(self, db: float, floor: float, playing: bool, client: bool) -> tuple[bool, bool]:
        if client:
            # The floor follows the room's quiet moments; babble also has a typical level (its
            # median) a few dB above that. Bars are over whichever is higher.
            mid = self.room_mid if self.room_mid is not None else floor
            under = self.level is not None and db < self.level - self.CLIENT_BELOW_SPEECH
            if self.active:
                bar = max(floor + self.CLIENT_TALK, mid + self.CLIENT_TALK_OVER_MID)
            else:
                bar = max(floor + self.CLIENT_ONSET, mid + self.CLIENT_ONSET_OVER_MID)
            if playing:
                bar += 6
            # Far-field talkers: near-field speech (his) is ~10 dB over them; only a chunk within
            # 8 dB of his own level keeps his turn going.
            near = self.level is None or db >= self.level - self.CLIENT_NEAR
            speech = db > max(bar, -40.0 if playing else -50.0) and not under and near
            quiet = not speech and (db < max(floor + self.CLIENT_QUIET, mid + self.CLIENT_QUIET_OVER_MID)
                                    or under or not near)
            return speech, quiet
        under = self.level is not None and db < self.level - self.BELOW_SPEECH
        over = (self.SPEECH_OVER_FLOOR + 6, -40.0) if playing else (self.SPEECH_OVER_FLOOR, -50.0)
        speech = db > max(floor + over[0], over[1]) and not under
        quiet = not speech and (db < floor + self.QUIET_OVER_FLOOR or under)
        return speech, quiet

    def feed(self, db: float, dur: float = 0.1, server_heard: bool = True, client: bool = False,
             playing: bool = False) -> str | None:
        """One mic chunk. Returns None, or (server mode) "end:<reason>", or (client mode)
        "start" / "end:<reason>"."""
        floor, cal = self.room.floor, self.room.calibrated
        self.room.observe(db, playing, dur)
        if not cal:
            return None
        if not self.active and self.room.window:
            levels = sorted(v for v, _ in self.room.window)
            self.room_mid = levels[len(levels) // 2]
        speech, quiet = self._classify(db, floor, playing, client)
        if client and not self.active:
            self.recent.append((speech, db, dur))
            total = sum(d for _, _, d in self.recent)
            while self.recent and total - self.recent[0][2] >= self.ONSET_WINDOW:
                total -= self.recent.pop(0)[2]
            voiced = [(v, d) for s, v, d in self.recent if s]
            if sum(d for _, d in voiced) >= self.ONSET_SPEECH - 1e-6:
                self.active = True
                self.speech = sum(d for _, d in voiced)
                self.level = sum(v for v, _ in voiced) / len(voiced)
                self.quiet, self.turn_time, self.recent = 0.0, 0.0, []
                return "start"
            return None
        if self.speech > 0 or self.active:
            self.turn_time += dur
        if speech:
            self.level = db if self.level is None else self._track_level(db, client)
            self.speech += dur
            self.talk_run += dur
            # Client mode: one loud chunk (a babble peak) doesn't reset the quiet timer; a word does.
            if not client or self.talk_run >= self.CLIENT_WORD - 1e-6:
                self.quiet = 0.0
        else:
            self.talk_run = 0.0
            if quiet:
                self.quiet += dur
            elif not client:
                self.quiet = 0.0  # server mode: maybe a soft word, keep waiting (unchanged)
            # client mode, in between (a babble peak near his level): hold the timer
        if client:
            if self.quiet >= self.CLIENT_QUIET_TO_END:
                return self.end("quiet" if self.heard_speech else "short")
            if self.turn_time >= self.MAX_TURN:
                return self.end("max")
            return None
        if self.heard_speech and self.turn_time >= self.MAX_TURN:
            return self.end("max")
        if self.heard_speech and server_heard and self.quiet >= self.QUIET_TO_END:
            return self.end("quiet")
        return None

    def _track_level(self, db: float, client: bool) -> float:
        """His talking level. Client mode: rises quickly, and only a chunk near it pulls it down, so
        a far-field talker counted as speech doesn't drag it toward the room."""
        if not client or db > self.level:
            return self.level + (db - self.level) * 0.2
        if db >= self.level - 4:
            return self.level + (db - self.level) * 0.05
        return self.level

    def end(self, reason: str) -> str:
        self.speech, self.level, self.quiet = 0.0, None, 0.0
        self.active, self.turn_time, self.recent, self.talk_run = False, 0.0, [], 0.0
        return "end:" + reason
