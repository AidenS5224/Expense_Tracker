from __future__ import annotations

import math
import tkinter as tk
from datetime import date, timedelta
from decimal import Decimal
from pathlib import Path
from tkinter import filedialog, messagebox, simpledialog, ttk

from .analytics import (
    calculated_balances,
    category_spend,
    current_week_budget,
    entry_balance_delta,
    goal_progress,
    income_vs_spend,
    monthly_flow,
)
from .importers import import_accounts_csv, import_statement
from .models import Entry, Goal, RecurringPayment
from .projection import minimum_savings_projection, minimum_weekly_rate
from .storage import TrackerStore
from .util import add_months, fmt_money, money, new_id, parse_date

try:
    from PIL import Image, ImageDraw, ImageFont, ImageTk
except Exception:  # pragma: no cover - optional render path
    Image = ImageDraw = ImageFont = ImageTk = None


BG = "#f3eee7"
PANEL = "#fffdf9"
BORDER = "#b8aa9d"
TEXT = "#1f1712"
MUTED = "#71665c"
GREEN = "#2f855a"
RED = "#b42318"
BLUE = "#315c72"
BROWN = "#885c2a"
SELECT = "#2f5f73"


class ChartCanvas(tk.Canvas):
    def __init__(self, master, **kwargs):
        super().__init__(master, bg=PANEL, highlightthickness=0, **kwargs)
        self._chart_image = None

    def _money_axis(self, value: float) -> str:
        rounded = round(value, 2)
        if abs(rounded) >= 1000:
            return f"${rounded:,.0f}"
        return f"${rounded:,.2f}"

    def _nice_step(self, raw_step: float) -> float:
        if raw_step <= 0:
            return 100.0
        power = 10 ** math.floor(math.log10(raw_step))
        scaled = raw_step / power
        if scaled <= 1:
            nice = 1
        elif scaled <= 2:
            nice = 2
        elif scaled <= 5:
            nice = 5
        else:
            nice = 10
        return nice * power

    def _axis_bounds(self, values: list[float], force_zero_min: bool = False) -> tuple[float, float, float]:
        if not values:
            return -100.0, 100.0, 50.0
        min_v = min(values)
        max_v = max(values)
        if force_zero_min:
            min_v = min(0.0, min_v)
        else:
            min_v = min(min_v, 0.0)
        max_v = max(max_v, 0.0)
        if min_v == max_v:
            pad = max(abs(max_v) * 0.2, 100.0)
            min_v -= pad
            max_v += pad
        span = max_v - min_v
        step = self._nice_step(span / 4)
        axis_min = math.floor(min_v / step) * step
        axis_max = math.ceil(max_v / step) * step
        if axis_min == axis_max:
            axis_max += step
        return axis_min, axis_max, step

    def _truncate(self, text: str, max_chars: int) -> str:
        if len(text) <= max_chars:
            return text
        return text[: max(1, max_chars - 1)] + "..."

    def _font(self, size: int, bold: bool = False):
        if not ImageFont:
            return None
        for name in (("segoeuib.ttf" if bold else "segoeui.ttf"), "arial.ttf"):
            try:
                return ImageFont.truetype(name, size)
            except Exception:
                pass
        return ImageFont.load_default()

    def _text(self, draw, xy, text: str, fill: str, font, anchor: str = "la") -> None:
        try:
            draw.text(xy, text, fill=fill, font=font, anchor=anchor)
        except TypeError:
            draw.text(xy, text, fill=fill, font=font)

    def _line(self, draw, xy, fill: str, width: int = 1, dash=None) -> None:
        if not dash:
            draw.line(xy, fill=fill, width=width)
            return
        x0, y0, x1, y1 = xy
        dx, dy = x1 - x0, y1 - y0
        length = math.hypot(dx, dy)
        if length <= 0:
            return
        ux, uy = dx / length, dy / length
        position = 0.0
        draw_on = True
        dash_values = list(dash)
        dash_index = 0
        while position < length:
            segment = dash_values[dash_index % len(dash_values)]
            next_position = min(length, position + segment)
            if draw_on:
                draw.line(
                    (
                        x0 + ux * position,
                        y0 + uy * position,
                        x0 + ux * next_position,
                        y0 + uy * next_position,
                    ),
                    fill=fill,
                    width=width,
                )
            draw_on = not draw_on
            dash_index += 1
            position = next_position

    def _draw_lines_pillow(self, title: str, rows: list[dict], series: list[tuple]) -> bool:
        if not Image or not ImageDraw or not ImageTk:
            return False

        width = max(self.winfo_width(), 400)
        height = max(self.winfo_height(), 220)
        scale = 2
        image = Image.new("RGB", (width * scale, height * scale), PANEL)
        draw = ImageDraw.Draw(image)

        def s(value):
            return value * scale

        title_font = self._font(11 * scale, True)
        label_font = self._font(8 * scale)
        left, right, top, bottom = [s(v) for v in (74, 118, 38, 44)]
        plot_w = max(1, s(width) - left - right)
        plot_h = max(1, s(height) - top - bottom)

        values = [
            float(row[item[0]])
            for row in rows
            for item in series
            if item[0] in row and row[item[0]] is not None
        ]
        self.delete("all")
        if not values:
            self._text(draw, (s(width / 2), s(height / 2)), "No data", MUTED, self._font(10 * scale), "mm")
        else:
            min_v, max_v, step = self._axis_bounds(values)

            def x_at(index: int) -> float:
                if len(rows) <= 1:
                    return left + plot_w / 2
                return left + (plot_w * index / (len(rows) - 1))

            def y_at(value: float) -> float:
                return top + (max_v - value) / (max_v - min_v) * plot_h

            self._text(draw, (s(width / 2), s(18)), title, TEXT, title_font, "mm")
            tick = min_v
            while tick <= max_v + (step / 2):
                y = y_at(tick)
                self._line(draw, (left, y, left + plot_w, y), "#e1d7ce", scale)
                self._text(draw, (left - s(8), y), self._money_axis(tick), TEXT, label_font, "rm")
                tick += step

            zero_y = y_at(0)
            self._line(draw, (left, zero_y, left + plot_w, zero_y), "#44372e", 2 * scale)

            label_every = max(1, math.ceil(len(rows) / max(1, int((plot_w / scale) / 78))))
            for index, row in enumerate(rows):
                x = x_at(index)
                if index % label_every == 0 or index == len(rows) - 1:
                    self._line(draw, (x, top, x, top + plot_h), "#eadfd5", scale)
                    label = self._truncate(str(row.get("label", "")), 10)
                    self._text(draw, (x, top + plot_h + s(20)), label, TEXT, label_font, "mm")

            for item in series:
                name, color = item[0], item[1]
                dash = tuple(v * scale for v in item[2]) if len(item) > 2 and item[2] else None
                points = []
                for index, row in enumerate(rows):
                    if name not in row or row[name] is None:
                        points.append(None)
                    else:
                        points.append((x_at(index), y_at(float(row[name]))))
                previous = None
                visible_points = []
                for point in points:
                    if point is None:
                        previous = None
                        continue
                    visible_points.append(point)
                    if previous is not None:
                        self._line(draw, (*previous, *point), color, 2 * scale, dash)
                    previous = point
                if len(visible_points) <= 36:
                    radius = 3 * scale
                    for x, y in visible_points:
                        draw.ellipse((x - radius, y - radius, x + radius, y + radius), outline=color, fill=color)

            legend_x = s(width) - right + s(14)
            for index, item in enumerate(series):
                name, color = item[0], item[1]
                dash = tuple(v * scale for v in item[2]) if len(item) > 2 and item[2] else None
                y = top + s(14) + index * s(20)
                self._line(draw, (legend_x, y, legend_x + s(22), y), color, 2 * scale, dash)
                self._text(draw, (legend_x + s(28), y), self._truncate(name, 18), TEXT, label_font, "lm")

        image = image.resize((width, height), Image.Resampling.LANCZOS)
        self._chart_image = ImageTk.PhotoImage(image)
        self.create_image(0, 0, image=self._chart_image, anchor="nw")
        return True

    def draw_lines(self, title: str, rows: list[dict], series: list[tuple]) -> None:
        if self._draw_lines_pillow(title, rows, series):
            return
        self.delete("all")
        width = max(self.winfo_width(), 400)
        height = max(self.winfo_height(), 220)
        left, right, top, bottom = 74, 118, 38, 44
        plot_w = max(1, width - left - right)
        plot_h = max(1, height - top - bottom)
        self.create_text(width / 2, 18, text=title, fill=TEXT, font=("Segoe UI", 11, "bold"))
        values = [
            float(row[item[0]])
            for row in rows
            for item in series
            if item[0] in row and row[item[0]] is not None
        ]
        if not values:
            self.create_text(width / 2, height / 2, text="No data", fill=MUTED, font=("Segoe UI", 10))
            return
        min_v, max_v, step = self._axis_bounds(values)

        def x_at(index: int) -> float:
            if len(rows) <= 1:
                return left + plot_w / 2
            return left + (plot_w * index / (len(rows) - 1))

        def y_at(value: float) -> float:
            return top + (max_v - value) / (max_v - min_v) * plot_h

        tick = min_v
        while tick <= max_v + (step / 2):
            value = tick
            y = y_at(value)
            self.create_line(left, y, left + plot_w, y, fill="#e1d7ce")
            self.create_text(left - 8, y, text=self._money_axis(value), fill=TEXT, font=("Segoe UI", 8), anchor="e")
            tick += step
        zero_y = y_at(0)
        self.create_line(left, zero_y, left + plot_w, zero_y, fill="#44372e", width=2)

        label_every = max(1, math.ceil(len(rows) / max(1, int(plot_w / 78))))
        for index, row in enumerate(rows):
            x = x_at(index)
            if index % label_every == 0 or index == len(rows) - 1:
                self.create_line(x, top, x, top + plot_h, fill="#eadfd5")
                label = self._truncate(str(row.get("label", "")), 10)
                self.create_text(x, top + plot_h + 20, text=label, fill=TEXT, font=("Segoe UI", 8))

        for item in series:
            name, color = item[0], item[1]
            dash = item[2] if len(item) > 2 else None
            points = []
            for index, row in enumerate(rows):
                if name not in row or row[name] is None:
                    points.append(None)
                else:
                    points.append((x_at(index), y_at(float(row[name]))))
            previous = None
            visible_points = []
            for point in points:
                if point is None:
                    previous = None
                    continue
                visible_points.append(point)
                if previous is not None:
                    self.create_line(*previous, *point, fill=color, width=2, dash=dash)
                previous = point
            if len(visible_points) <= 36:
                for x, y in visible_points:
                    self.create_oval(x - 3, y - 3, x + 3, y + 3, outline=color, fill=color)

        legend_x = width - right + 14
        for index, item in enumerate(series):
            name, color = item[0], item[1]
            dash = item[2] if len(item) > 2 else None
            y = top + 14 + index * 20
            self.create_line(legend_x, y, legend_x + 22, y, fill=color, width=2, dash=dash)
            self.create_text(legend_x + 28, y, text=self._truncate(name, 18), fill=TEXT, font=("Segoe UI", 8), anchor="w")

    def draw_bars(self, title: str, rows: list[dict], series: list[tuple[str, str]], force_zero_min: bool = True) -> None:
        self.delete("all")
        width = max(self.winfo_width(), 400)
        height = max(self.winfo_height(), 220)
        left, right, top, bottom = 74, 118, 38, 54
        plot_w = max(1, width - left - right)
        plot_h = max(1, height - top - bottom)
        self.create_text(width / 2, 18, text=title, fill=TEXT, font=("Segoe UI", 11, "bold"))
        values = [float(row.get(name, 0) or 0) for row in rows for name, _ in series]
        if not values:
            self.create_text(width / 2, height / 2, text="No data", fill=MUTED, font=("Segoe UI", 10))
            return
        min_v, max_v, step = self._axis_bounds(values, force_zero_min)

        def y_at(value: float) -> float:
            return top + (max_v - value) / (max_v - min_v) * plot_h

        tick = min_v
        while tick <= max_v + (step / 2):
            y = y_at(tick)
            self.create_line(left, y, left + plot_w, y, fill="#e1d7ce")
            self.create_text(left - 8, y, text=self._money_axis(tick), fill=TEXT, font=("Segoe UI", 8), anchor="e")
            tick += step
        zero_y = y_at(0)
        self.create_line(left, zero_y, left + plot_w, zero_y, fill="#44372e", width=2)

        row_count = max(1, len(rows))
        group_w = plot_w / row_count
        bar_gap = 4
        bar_w = max(3, min(34, (group_w - 12) / max(1, len(series))))
        for index, row in enumerate(rows):
            group_left = left + index * group_w
            center = group_left + group_w / 2
            for series_index, (name, color) in enumerate(series):
                value = float(row.get(name, 0) or 0)
                x0 = center - (bar_w * len(series) + bar_gap * (len(series) - 1)) / 2 + series_index * (bar_w + bar_gap)
                x1 = x0 + bar_w
                y0 = y_at(max(0, value))
                y1 = y_at(min(0, value))
                self.create_rectangle(x0, y0, x1, y1, fill=color, outline=color)
            label = self._truncate(str(row.get("label", "")), max(5, int(group_w / 7)))
            self.create_text(center, top + plot_h + 22, text=label, fill=TEXT, font=("Segoe UI", 8))

        legend_x = width - right + 14
        for index, (name, color) in enumerate(series):
            y = top + 14 + index * 20
            self.create_rectangle(legend_x, y - 5, legend_x + 18, y + 5, fill=color, outline=color)
            self.create_text(legend_x + 26, y, text=self._truncate(name, 18), fill=TEXT, font=("Segoe UI", 8), anchor="w")

    def draw_table(self, title: str, headers: list[str], rows: list[list[str]], danger_rows: set[int] | None = None) -> None:
        danger_rows = danger_rows or set()
        self.delete("all")
        width = max(self.winfo_width(), 400)
        height = max(self.winfo_height(), 220)
        self.create_text(8, 14, text=title, fill=TEXT, font=("Segoe UI", 11, "bold"), anchor="w")
        x0, y0 = 8, 34
        row_h = 22
        col_widths = [max(120, int((width - 16) * ratio)) for ratio in (0.20, 0.16, 0.64)]
        total_width = sum(col_widths)
        self.create_rectangle(x0, y0, x0 + total_width, y0 + row_h, fill="#ebe2d8", outline=BORDER)
        x = x0
        for idx, header in enumerate(headers):
            self.create_text(x + 6, y0 + row_h / 2, text=header, fill=TEXT, font=("Segoe UI", 8, "bold"), anchor="w")
            self.create_line(x, y0, x, y0 + row_h, fill=BORDER)
            x += col_widths[idx]
        self.create_line(x0 + total_width, y0, x0 + total_width, y0 + row_h, fill=BORDER)

        for row_index, row in enumerate(rows):
            y = y0 + row_h * (row_index + 1)
            if y + row_h > height - 8:
                break
            fill = PANEL if row_index % 2 == 0 else "#f7f2ec"
            self.create_rectangle(x0, y, x0 + total_width, y + row_h, fill=fill, outline="#d5c8bc")
            x = x0
            for col_index, text in enumerate(row):
                color = RED if row_index in danger_rows else TEXT
                anchor = "e" if col_index == 1 else "w"
                tx = x + col_widths[col_index] - 8 if anchor == "e" else x + 6
                self.create_text(tx, y + row_h / 2, text=str(text), fill=color, font=("Consolas", 9), anchor=anchor)
                x += col_widths[col_index]


class TrackerApp(tk.Tk):
    def __init__(self, store: TrackerStore):
        super().__init__()
        self.store = store
        self.title("Expense Savings Tracker")
        self.geometry("1500x900")
        self.minsize(1100, 720)
        self.configure(bg=BG)

        self.entries: list[Entry] = []
        self.goals: list[Goal] = []
        self.recurring: list[RecurringPayment] = []
        self.account_names: dict[str, str] = {}
        self.account_balance_anchors = {}
        self.balance_rows = {}
        self.goal_rows = []
        self.minimum_weekly = money(0)
        self.projection_peak = money(0)
        self.projection_points = []
        self._refresh_job = None
        self.selected_account = tk.StringVar(value="All Accounts")
        self.view_filter = tk.StringVar(value="All")
        self.month_filter = tk.StringVar(value="All Months")
        self.transaction_account_filter = tk.StringVar(value="All Accounts")
        self.search_text = tk.StringVar(value="")
        self.sort_filter = tk.StringVar(value="Newest first")
        self.left_graph = tk.StringVar(value=self.store.setting("LeftGraphDefault", "Data Table") or "Data Table")
        self.right_graph = tk.StringVar(value=self.store.setting("RightGraphDefault", "Income vs Spend") or "Income vs Spend")

        self._build_style()
        self._build_layout()
        self.refresh()

    def _build_style(self) -> None:
        style = ttk.Style(self)
        style.theme_use("clam")
        style.configure(".", background=BG, foreground=TEXT, font=("Segoe UI", 9))
        style.configure("Treeview", background=PANEL, fieldbackground=PANEL, foreground=TEXT, rowheight=24, bordercolor=BORDER)
        style.map("Treeview", background=[("selected", SELECT)], foreground=[("selected", "white")])
        style.configure("TButton", padding=(12, 6), background=PANEL, bordercolor="#d0b8a6")
        style.configure("TCombobox", fieldbackground=PANEL, background=PANEL)

    def _build_layout(self) -> None:
        top = tk.Frame(self, bg=BG)
        top.pack(fill="x", padx=10, pady=(8, 4))
        tk.Label(top, text="Expense Savings Tracker", bg=BG, fg=TEXT, font=("Segoe UI", 18, "bold")).pack(side="left")
        buttons = tk.Frame(top, bg=BG)
        buttons.pack(side="right")
        for label, command in [
            ("Help", self.show_help),
            ("Settings", self.show_settings),
            ("Refresh", self.refresh),
            ("Sync Data", self.sync_legacy_data),
            ("Import Statement", self.import_statement),
            ("Import Accounts", self.import_accounts),
            ("Name Accounts", self.name_account),
            ("Export CSV", self.export_csv),
            ("Backup", self.backup_data),
            ("Restore", self.restore_data),
        ]:
            ttk.Button(buttons, text=label, command=command).pack(side="left", padx=3)

        self.cards = {}
        cards = tk.Frame(self, bg=BG)
        cards.pack(fill="x", padx=10, pady=4)
        for key, label in [
            ("remaining", "REMAINING BUDGET"),
            ("bills", "BILLS"),
            ("paycheck", "PAYCHECK"),
            ("min_savings", "MIN SAVINGS"),
            ("spend", "SPEND"),
        ]:
            frame = tk.Frame(cards, bg=PANEL, highlightthickness=1, highlightbackground=BORDER, height=66)
            frame.pack(side="left", fill="x", expand=True, padx=4)
            tk.Label(frame, text=label, bg=PANEL, fg=MUTED, font=("Segoe UI", 8, "bold")).pack(anchor="w", padx=10, pady=(8, 0))
            value = tk.Label(frame, text="$0.00", bg=PANEL, fg=TEXT, font=("Segoe UI", 15, "bold"))
            value.pack(anchor="w", padx=10)
            self.cards[key] = value

        graph_area = tk.Frame(self, bg=BG)
        graph_area.pack(fill="both", expand=False, padx=10, pady=4)
        self.left_panel = self._graph_panel(graph_area, self.left_graph)
        self.left_panel.pack(side="left", fill="both", expand=True, padx=(0, 5))
        self.right_panel = self._graph_panel(graph_area, self.right_graph)
        self.right_panel.pack(side="left", fill="both", expand=True, padx=(5, 0))

        mid = tk.Frame(self, bg=BG)
        mid.pack(fill="both", expand=False, padx=10, pady=4)
        self.category_tree = self._section_tree(mid, "Category Spend", [("Category", 190), ("Amount", 110)], 5)
        self.balance_tree = self._section_tree(mid, "Current Balances", [("Account", 220), ("Balance", 100), ("Date", 90)], 5)
        self.recurring_tree = self._section_tree(mid, "Recurring Payments", [("Name", 330), ("Amount", 90), ("Frequency", 100), ("Date", 90)], 5)
        self.goals_tree = self._goals_section_tree(mid)
        self.goals_tree.bind("<Double-1>", lambda _event: self.edit_selected_goal())

        transactions_frame = tk.Frame(self, bg=BG)
        transactions_frame.pack(fill="both", expand=True, padx=10, pady=(4, 10))
        transaction_header = tk.Frame(transactions_frame, bg=BG)
        transaction_header.pack(fill="x")
        tk.Label(transaction_header, text="Transactions", bg=BG, fg=TEXT, font=("Segoe UI", 10, "bold")).pack(side="left")

        filter_bar = tk.Frame(transactions_frame, bg=BG)
        filter_bar.pack(fill="x", pady=(3, 4))
        self.view_combo = ttk.Combobox(filter_bar, textvariable=self.view_filter, state="readonly", width=14, values=("All", "Expense", "Saving", "Income", "Bill"))
        self.view_combo.pack(side="left", padx=(0, 6))
        self.view_combo.bind("<<ComboboxSelected>>", lambda _event: self._refresh_tables())
        self.month_combo = ttk.Combobox(filter_bar, textvariable=self.month_filter, state="readonly", width=14)
        self.month_combo.pack(side="left", padx=6)
        self.month_combo.bind("<<ComboboxSelected>>", lambda _event: self._refresh_tables_and_graphs())
        self.transaction_account_combo = ttk.Combobox(filter_bar, textvariable=self.transaction_account_filter, state="readonly", width=28)
        self.transaction_account_combo.pack(side="left", padx=6)
        self.transaction_account_combo.bind("<<ComboboxSelected>>", lambda _event: self._refresh_tables_and_graphs())
        search = ttk.Entry(filter_bar, textvariable=self.search_text, width=30)
        search.pack(side="left", padx=6)
        search.bind("<KeyRelease>", lambda _event: self._refresh_tables())
        self.sort_combo = ttk.Combobox(filter_bar, textvariable=self.sort_filter, state="readonly", width=16, values=("Newest first", "Oldest first", "Amount high", "Amount low"))
        self.sort_combo.pack(side="left", padx=6)
        self.sort_combo.bind("<<ComboboxSelected>>", lambda _event: self._refresh_tables())
        ttk.Button(filter_bar, text="Delete Selected", command=self.delete_selected_entries).pack(side="right", padx=(6, 0))
        ttk.Button(filter_bar, text="Edit Selected", command=self.edit_selected_entry).pack(side="right", padx=3)
        ttk.Button(filter_bar, text="Add Recurring", command=self.add_recurring_from_selection).pack(side="right", padx=3)
        ttk.Button(filter_bar, text="Mark Income", command=self.mark_income).pack(side="right", padx=3)
        ttk.Button(filter_bar, text="Add Entry", command=self.add_entry).pack(side="right", padx=3)

        self.transactions = self._tree(
            transactions_frame,
            [
                ("Date", 90),
                ("Type", 80),
                ("Narrative / Name", 360),
                ("Category", 140),
                ("Account", 190),
                ("Amount", 95),
                ("Bank Category", 130),
                ("Note", 300),
            ],
            height=12,
        )
        self.transactions.pack(fill="both", expand=True)
        self.transactions.bind("<Double-1>", lambda _event: self.edit_selected_entry())
        self._drag_anchor: str | None = None
        self._dragging_transactions = False
        self.transactions.bind("<ButtonPress-1>", self._start_transaction_drag, add="+")
        self.transactions.bind("<B1-Motion>", self._drag_transaction_selection, add="+")
        self.transactions.bind("<ButtonRelease-1>", self._end_transaction_drag, add="+")

    def _graph_panel(self, master, variable: tk.StringVar) -> tk.Frame:
        frame = tk.Frame(master, bg=BG)
        header = tk.Frame(frame, bg=BG)
        header.pack(fill="x")
        combo = ttk.Combobox(header, textvariable=variable, state="readonly", width=22)
        combo["values"] = ("Data Table", "Income vs Spend", "Monthly Flow", "Savings Projection", "Savings Goals", "Balances")
        combo.pack(side="left")
        combo.bind("<<ComboboxSelected>>", lambda _event: self.refresh_graphs())
        canvas = ChartCanvas(frame, height=330)
        canvas.pack(fill="both", expand=True, pady=(4, 0))
        canvas.bind("<Configure>", lambda _event: self.schedule_graph_refresh())
        frame.canvas = canvas
        frame.combo = combo
        return frame

    def schedule_graph_refresh(self) -> None:
        if self._refresh_job:
            self.after_cancel(self._refresh_job)
        self._refresh_job = self.after(80, self.refresh_graphs)

    def _section_tree(self, master, title: str, columns: list[tuple[str, int]], height: int) -> ttk.Treeview:
        frame = tk.Frame(master, bg=BG)
        frame.pack(side="left", fill="both", expand=True, padx=4)
        tk.Label(frame, text=title, bg=BG, fg=TEXT, font=("Segoe UI", 10, "bold")).pack(anchor="w")
        tree = self._tree(frame, columns, height=height)
        tree.pack(fill="both", expand=True)
        return tree

    def _goals_section_tree(self, master) -> ttk.Treeview:
        frame = tk.Frame(master, bg=BG)
        frame.pack(side="left", fill="both", expand=True, padx=4)
        header = tk.Frame(frame, bg=BG)
        header.pack(fill="x")
        tk.Label(header, text="Savings Goals", bg=BG, fg=TEXT, font=("Segoe UI", 10, "bold")).pack(side="left")
        ttk.Button(header, text="Delete Goal", command=self.delete_selected_goal).pack(side="right", padx=(3, 0))
        ttk.Button(header, text="Edit Goal", command=self.edit_selected_goal).pack(side="right", padx=3)
        ttk.Button(header, text="Add Goal", command=self.add_goal).pack(side="right", padx=3)
        tree = self._tree(frame, [("Name", 160), ("Account", 210), ("Progress", 80), ("Saved", 90), ("Target", 90), ("Due", 90)], height=5)
        tree.pack(fill="both", expand=True)
        return tree

    def _tree(self, master, columns: list[tuple[str, int]], height: int) -> ttk.Treeview:
        names = [name for name, _ in columns]
        tree = ttk.Treeview(master, columns=names, show="headings", height=height, selectmode="extended")
        for name, width in columns:
            tree.heading(name, text=name)
            anchor = "e" if name in {"Amount", "Balance", "Saved", "Target"} else "w"
            tree.column(name, width=width, minwidth=40, anchor=anchor, stretch=True)
        yscroll = ttk.Scrollbar(master, orient="vertical", command=tree.yview)
        tree.configure(yscrollcommand=yscroll.set)
        return tree

    def refresh(self) -> None:
        self.entries = self.store.entries()
        self.goals = self.store.goals()
        self.recurring = self.store.recurring_payments()
        self.account_names = self.store.account_names()
        self.account_balance_anchors = self.store.account_balances()
        self.balance_rows = calculated_balances(self.entries, self.account_balance_anchors, self.account_names)
        self.goal_rows = goal_progress(self.goals, self.balance_rows)
        self.projection_peak, self.projection_points = minimum_savings_projection(self.goal_rows)
        self.minimum_weekly = minimum_weekly_rate(self.goal_rows)
        self._refresh_accounts()
        self._refresh_filter_options()
        self._refresh_cards()
        self._refresh_tables()
        self.refresh_graphs()

    def _refresh_accounts(self) -> None:
        current = self.selected_account.get()
        accounts = sorted({entry.account for entry in self.entries if entry.account} | {goal.account for goal in self.goals if goal.account} | set(self.account_balance_anchors.keys()))
        values = ["All Accounts"] + [self.display_account(account) for account in accounts]
        self.account_values = values
        self.account_lookup = {"All Accounts": "All Accounts"} | {self.display_account(account): account for account in accounts}
        if current not in values:
            self.selected_account.set("All Accounts")

    def _refresh_filter_options(self) -> None:
        months = sorted({entry.date.strftime("%Y-%m") for entry in self.entries}, reverse=True)
        current_month = self.month_filter.get()
        self.month_combo["values"] = ["All Months"] + months
        if current_month not in self.month_combo["values"]:
            self.month_filter.set("All Months")

        current_account = self.transaction_account_filter.get()
        values = list(getattr(self, "account_values", ["All Accounts"]))
        self.transaction_account_combo["values"] = values
        if current_account not in values:
            self.transaction_account_filter.set("All Accounts")

    def _refresh_tables_and_graphs(self) -> None:
        self._refresh_tables()
        self.schedule_graph_refresh()

    def _selected_account_raw(self) -> str:
        return self.account_lookup.get(self.selected_account.get(), "All Accounts")

    def _transaction_account_raw(self) -> str:
        return self.account_lookup.get(self.transaction_account_filter.get(), "All Accounts")

    def _graph_scope_account_raw(self) -> str:
        return self._transaction_account_raw()

    def _graph_scope_account_label(self) -> str:
        return self.transaction_account_filter.get()

    def _graph_scope_month(self) -> str:
        return self.month_filter.get()

    def _graph_scope_label(self) -> str:
        month = self._graph_scope_month()
        return "All Months" if month == "All Months" else month

    def display_account(self, account: str) -> str:
        name = self.account_names.get(account, "")
        return f"{name} ({account})" if name and name != account else account

    def _refresh_cards(self) -> None:
        budget = current_week_budget(
            self.entries,
            self.goals,
            self.recurring,
            self.balance_rows,
            self.account_names,
            self.account_balance_anchors,
            self.minimum_weekly,
        )
        values = {
            "remaining": budget.remaining,
            "paycheck": budget.paycheck,
            "min_savings": self.minimum_weekly,
            "bills": budget.bills,
            "spend": budget.spend,
        }
        for key, value in values.items():
            self.cards[key].configure(text=fmt_money(value), fg=GREEN if key == "remaining" and value >= 0 else (RED if value < 0 else TEXT))

    def _refresh_tables(self) -> None:
        self._clear(self.category_tree)
        for category, amount in category_spend(self.entries)[:20]:
            self.category_tree.insert("", "end", values=(category, fmt_money(amount)))

        self._clear(self.balance_tree)
        hidden = self.store.hidden_balance_accounts()
        for account, (balance, day, _source) in sorted(self.balance_rows.items(), key=lambda item: self.display_account(item[0])):
            if account in hidden:
                continue
            self.balance_tree.insert("", "end", values=(self.display_account(account), fmt_money(balance), day.strftime("%d/%m/%Y")))

        self._clear(self.recurring_tree)
        for payment in self.recurring:
            self.recurring_tree.insert("", "end", iid=payment.key, values=(payment.name, fmt_money(payment.amount), payment.frequency, payment.date.strftime("%d/%m/%Y")))

        self._clear(self.goals_tree)
        for goal, saved, remaining in self.goal_rows:
            target = goal.weekly_amount if goal.goal_kind == "Weekly" else goal.target_amount
            progress = "100%" if target <= 0 else f"{min(100, int((saved / target) * 100))}%"
            self.goals_tree.insert("", "end", iid=goal.id, values=(goal.name, self.display_account(goal.account), progress, fmt_money(saved), fmt_money(target), goal.expected_date.strftime("%d/%m/%Y")))

        self._clear(self.transactions)
        account = self.account_lookup.get(self.transaction_account_filter.get(), "All Accounts")
        rows = list(self.entries)
        if self.view_filter.get() != "All":
            rows = [entry for entry in rows if entry.type == self.view_filter.get()]
        if self.month_filter.get() != "All Months":
            rows = [entry for entry in rows if entry.date.strftime("%Y-%m") == self.month_filter.get()]
        if account != "All Accounts":
            rows = [entry for entry in rows if entry.account == account]
        search = self.search_text.get().strip().lower()
        if search:
            rows = [
                entry for entry in rows
                if search in entry.name.lower()
                or search in entry.category.lower()
                or search in entry.account.lower()
                or search in entry.bank_category.lower()
                or search in entry.note.lower()
            ]
        sort_mode = self.sort_filter.get()
        if sort_mode == "Oldest first":
            rows.sort(key=lambda entry: (entry.date, entry.name))
        elif sort_mode == "Amount high":
            rows.sort(key=lambda entry: entry.amount, reverse=True)
        elif sort_mode == "Amount low":
            rows.sort(key=lambda entry: entry.amount)
        else:
            rows.sort(key=lambda entry: (entry.date, entry.name), reverse=True)

        for entry in rows[:2000]:
            if account != "All Accounts" and entry.account != account:
                continue
            self.transactions.insert(
                "",
                "end",
                iid=entry.id,
                values=(
                    entry.date.strftime("%d/%m/%Y"),
                    entry.type,
                    entry.name,
                    entry.category,
                    self.display_account(entry.account),
                    fmt_money(entry.amount),
                    entry.bank_category,
                    entry.note,
                ),
            )

    def refresh_graphs(self) -> None:
        self._refresh_job = None
        self._draw_graph(self.left_panel.canvas, self.left_graph.get())
        self._draw_graph(self.right_panel.canvas, self.right_graph.get())
        self._refresh_tables()

    def _draw_graph(self, canvas: ChartCanvas, mode: str) -> None:
        account = self._graph_scope_account_raw()
        account_label = self._graph_scope_account_label()
        month_filter = self._graph_scope_month()
        scope_label = self._graph_scope_label()
        if mode == "Income vs Spend":
            rows, labels = income_vs_spend(self.entries, account, self.account_names, self.account_balance_anchors, month_filter)
            series = []
            for label in labels:
                color = GREEN if label in {"Income", "Credit + Interest"} else RED if label in {"Out", "Payments"} else BLUE
                series.append((label, color))
            canvas.draw_lines(f"Income vs Spend - {account_label} - {scope_label}", rows, series)
        elif mode == "Monthly Flow":
            rows = monthly_flow(self.entries, self.goals, account, month_filter)
            canvas.draw_lines(f"Monthly Flow - {account_label} - {scope_label}", rows, [("Out", RED), ("Saved", GREEN), ("Net", BLUE)])
        elif mode == "Savings Projection":
            rows = self._projection_rows(limit_to_goals=True)
            goal_names = sorted({row["goal"] for row in rows})
            chart_rows = []
            for week_date in sorted({row["week_date"] for row in rows}):
                item = {"label": week_date.strftime("%d/%m")}
                total = money(0)
                for goal_name in goal_names:
                    item[goal_name] = money(0)
                for row in rows:
                    if row["week_date"] == week_date:
                        item[row["goal"]] = row["amount"]
                        total += row["amount"]
                item["Total"] = total
                chart_rows.append(item)
            colors = [BLUE, GREEN, RED, BROWN, "#7c3aed", "#0f766e", "#a16207"]
            series = [(name, colors[index % len(colors)]) for index, name in enumerate(goal_names)]
            series.append(("Total weekly savings", "#111111", (5, 3)))
            for row in chart_rows:
                row["Total weekly savings"] = row.pop("Total")
            canvas.draw_lines(f"Minimum Weekly Savings Projection - {scope_label}", chart_rows, series)
        elif mode == "Savings Goals":
            rows = self._savings_goal_balance_rows(account)
            canvas.draw_lines(f"Savings Goals - {account_label} - {scope_label}", rows, [("Saved balance", GREEN), ("Projected balance", BROWN, (5, 3))])
        elif mode == "Balances":
            rows, series = self._balance_history_rows(account)
            canvas.draw_lines(f"Balances - {account_label} - {scope_label}", rows, series)
        else:
            budget = current_week_budget(
                self.entries,
                self.goals,
                self.recurring,
                self.balance_rows,
                self.account_names,
                self.account_balance_anchors,
                self.minimum_weekly,
            )
            table_rows = [
                ["Week", "", f"{budget.week_start.strftime('%d/%m/%Y')} - {budget.week_end.strftime('%d/%m/%Y')}"],
                ["Paycheck", fmt_money(budget.paycheck), "Income marked inside this Monday budget week"],
                ["Other Income", fmt_money(budget.other_income), "External credits that are not paycheck or internal transfers"],
                ["Savings", fmt_money(budget.savings), "Minimum weekly saving to hit active goals"],
                ["Spend", fmt_money(budget.spend), "Expenses, excluding transfers"],
                ["Bills", fmt_money(budget.bills), "Bill entries and recurring payments due this week"],
                ["Debts", fmt_money(budget.debts), "Credit card payoff and future debt payments"],
                ["Remaining", fmt_money(budget.remaining), "Paycheck plus other income minus savings, spend, bills, and debts"],
            ]
            canvas.draw_table("Data Table", ["Item", "Amount", "Detail"], table_rows, {7} if budget.remaining < 0 else set())

    def _projection_rows(self, limit_to_goals: bool = False) -> list[dict[str, object]]:
        rows = []
        selected_account = self._graph_scope_account_raw()
        selected_month = self._graph_scope_month()
        goal_accounts = {goal.id: goal.account for goal in self.goals}
        for point in self.projection_points:
            if limit_to_goals and selected_account != "All Accounts" and goal_accounts.get(point.goal_id) != selected_account:
                continue
            if selected_month != "All Months" and point.date.strftime("%Y-%m") != selected_month:
                continue
            rows.append({"week_date": point.date, "goal": point.goal_name, "amount": point.allocation})
        return rows

    def _month_starts(self, future_months: int = 0) -> list[date]:
        selected_month = self._graph_scope_month()
        if selected_month != "All Months":
            year, month = selected_month.split("-", 1)
            start = date(int(year), int(month), 1)
            end = add_months(start, 1)
            days = []
            cursor = start
            while cursor < end:
                days.append(cursor)
                cursor += timedelta(days=1)
            return days
        start = date.today().replace(day=1)
        return [add_months(start, offset) for offset in range(-11, future_months + 1)]

    def _month_end(self, month_start: date) -> date:
        if self._graph_scope_month() != "All Months":
            return month_start
        return add_months(month_start, 1) - timedelta(days=1)

    def _period_label(self, period_start: date) -> str:
        return period_start.strftime("%d") if self._graph_scope_month() != "All Months" else period_start.strftime("%b")

    def _estimated_account_balance_at(self, target: date, account: str):
        anchor = self._best_balance_anchor_at(target, account) or self.account_balance_anchors.get(account)
        if anchor:
            balance = anchor.balance
            if target >= anchor.date:
                for entry in self.entries:
                    if entry.account == account and anchor.date < entry.date <= target:
                        balance += entry_balance_delta(entry, self.account_names, self.account_balance_anchors)
                return money(balance)
            for entry in self.entries:
                if entry.account == account and target < entry.date <= anchor.date:
                    balance -= entry_balance_delta(entry, self.account_names, self.account_balance_anchors)
            return money(balance)

        candidates = [entry for entry in self.entries if entry.account == account and entry.balance != 0 and entry.date <= target]
        if candidates:
            return max(candidates, key=lambda entry: entry.date).balance
        return None

    def _best_balance_anchor_at(self, target: date, account: str):
        candidates = []
        anchor = self.account_balance_anchors.get(account)
        if anchor and anchor.date <= target:
            candidates.append((anchor.date, 1, anchor))
        for entry in self.entries:
            if entry.account == account and entry.balance != 0 and entry.date <= target:
                candidates.append((entry.date, 0, entry))
        if not candidates:
            return None
        _day, _priority, item = max(candidates, key=lambda candidate: (candidate[0], candidate[1]))
        return item

    def _historical_account_balance_at(self, target: date, account: str):
        return self._estimated_account_balance_at(target, account)

    def _accounts_with_history(self, selected_account: str) -> list[str]:
        if selected_account != "All Accounts":
            return [selected_account]
        accounts = sorted({entry.account for entry in self.entries if entry.account} | set(self.account_balance_anchors.keys()), key=self.display_account)
        return accounts

    def _balance_history_rows(self, selected_account: str):
        accounts = self._accounts_with_history(selected_account)
        has_projection = selected_account != "All Accounts" and any(goal.account == selected_account for goal in self.goals)
        months = self._month_starts(6 if has_projection else 0)
        current_period = date.today() if self._graph_scope_month() != "All Months" else date.today().replace(day=1)
        ranges = {}
        for account in accounts:
            dates = [entry.date for entry in self.entries if entry.account == account]
            if account in self.account_balance_anchors:
                dates.append(self.account_balance_anchors[account].date)
            if dates:
                ranges[account] = (min(dates), max(dates))

        rows = []
        projected = self._estimated_account_balance_at(date.today(), selected_account) if has_projection else None
        for month_start in months:
            target = self._month_end(month_start)
            row = {"label": self._period_label(month_start)}
            for account in accounts:
                if account not in ranges:
                    continue
                first, last = ranges[account]
                if month_start > current_period or target < first or month_start > last:
                    continue
                value = self._historical_account_balance_at(target, account)
                if value is not None:
                    row[self.display_account(account)] = value
            if has_projection and projected is not None and target >= date.today():
                if month_start > current_period:
                    projected += self._projected_goal_savings_for_month(month_start, selected_account)
                projected -= self._projected_goal_send_for_month(month_start, selected_account)
                projected = max(money(0), money(projected))
                row["Projected balance"] = projected
            rows.append(row)

        colors = [BLUE, GREEN, RED, BROWN, "#7c3aed", "#0f766e", "#a16207", "#2563eb"]
        used_accounts = [account for account in accounts if any(self.display_account(account) in row for row in rows)]
        series = [(self.display_account(account), colors[index % len(colors)]) for index, account in enumerate(used_accounts)]
        if any("Projected balance" in row for row in rows):
            series.append(("Projected balance", BROWN, (5, 3)))
        return rows, series

    def _goal_accounts(self, selected_account: str) -> list[str]:
        accounts = sorted({goal.account for goal in self.goals if goal.account}, key=self.display_account)
        if selected_account != "All Accounts":
            accounts = [account for account in accounts if account == selected_account]
        return accounts

    def _savings_goal_balance_rows(self, selected_account: str) -> list[dict[str, object]]:
        accounts = self._goal_accounts(selected_account)
        current_period = date.today() if self._graph_scope_month() != "All Months" else date.today().replace(day=1)
        progress_rows = goal_progress(self.goals, self.balance_rows)
        projected_total = sum((saved for goal, saved, _remaining in progress_rows if goal.account in accounts), money(0))
        goal_target = sum((goal.target_amount for goal in self.goals if goal.account in accounts), money(0))
        rows = []
        for month_start in self._month_starts(6):
            target = self._month_end(month_start)
            row = {"label": self._period_label(month_start)}
            total = money(0)
            has_value = False
            if month_start <= current_period:
                for account in accounts:
                    value = self._historical_account_balance_at(target, account)
                    if value is not None:
                        total += max(money(0), value)
                        has_value = True
                if has_value and total != 0:
                    row["Saved balance"] = total
            if target >= date.today():
                monthly_add = sum((self._projected_goal_savings_for_month(month_start, account) for account in accounts), money(0))
                monthly_send = sum((self._projected_goal_send_for_month(month_start, account) for account in accounts), money(0))
                projected_total = min(goal_target, projected_total + monthly_add)
                projected_total = max(money(0), projected_total - monthly_send)
                row["Projected balance"] = projected_total
            rows.append(row)
        return rows

    def _projected_goal_savings_for_month(self, month_start: date, account: str):
        month_end = self._month_end(month_start)
        total = money(0)
        goal_accounts = {goal.id: goal.account for goal in self.goals}
        for point in self.projection_points:
            if month_start <= point.date <= month_end and goal_accounts.get(point.goal_id) == account:
                total += point.allocation
        return money(total)

    def _projected_goal_send_for_month(self, month_start: date, account: str):
        month_end = self._month_end(month_start)
        total = money(0)
        for goal in self.goals:
            if goal.account == account and goal.mode == "Send" and month_start <= goal.expected_date <= month_end:
                total += goal.target_amount
        return money(total)

    def _clear(self, tree: ttk.Treeview) -> None:
        for item in tree.get_children():
            tree.delete(item)

    def _start_transaction_drag(self, event) -> None:
        if self.transactions.identify_region(event.x, event.y) != "cell":
            self._drag_anchor = None
            self._dragging_transactions = False
            return
        row = self.transactions.identify_row(event.y)
        if not row:
            self._drag_anchor = None
            self._dragging_transactions = False
            return
        self._drag_anchor = row
        self._dragging_transactions = True
        if not (event.state & 0x0004):  # Ctrl keeps existing selection.
            self.transactions.selection_set(row)

    def _drag_transaction_selection(self, event) -> str:
        if not self._dragging_transactions or not self._drag_anchor:
            return ""
        row = self.transactions.identify_row(event.y)
        if not row:
            return "break"
        visible = list(self.transactions.get_children(""))
        if self._drag_anchor not in visible or row not in visible:
            return "break"
        start = visible.index(self._drag_anchor)
        end = visible.index(row)
        if start > end:
            start, end = end, start
        self.transactions.selection_set(visible[start:end + 1])
        self.transactions.focus(row)
        self.transactions.see(row)
        return "break"

    def _end_transaction_drag(self, _event) -> None:
        self._dragging_transactions = False

    def import_statement(self) -> None:
        path = filedialog.askopenfilename(title="Import Statement", filetypes=[("CSV files", "*.csv"), ("All files", "*.*")])
        if not path:
            return
        fallback = None
        try:
            result = import_statement(self.store, Path(path), fallback)
            self.refresh()
            messagebox.showinfo("Import Statement", f"Read {result.read} rows.\nImported {result.added} new transaction(s).\nSkipped {result.duplicates} duplicate(s) and {result.skipped_zero} zero-value row(s).")
        except Exception as exc:
            messagebox.showerror("Import Statement", str(exc))

    def import_accounts(self) -> None:
        path = filedialog.askopenfilename(title="Import Accounts", filetypes=[("CSV files", "*.csv"), ("All files", "*.*")])
        if not path:
            return
        try:
            result = import_accounts_csv(self.store, Path(path))
            self.refresh()
            messagebox.showinfo("Import Accounts", f"Read {result.read} rows.\nUpdated {result.added} account balance(s).")
        except Exception as exc:
            messagebox.showerror("Import Accounts", str(exc))

    def show_help(self) -> None:
        messagebox.showinfo(
            "Expense & Savings Tracker Help",
            "Use Mark Income or edit an entry to set your paycheck as Income.\n\n"
            "Remaining Budget = paycheck plus other income minus minimum savings, expected bills, debts, and spend.\n"
            "Bills = bill entries this week plus recurring payments due inside the week.\n"
            "The Python version is still being matched to the original app, so keep testing against the PowerShell version for now.",
        )

    def show_settings(self) -> None:
        messagebox.showinfo("Settings", "Settings are coming across in the next polish pass. Current defaults are Data Table on the left and Income vs Spend on the right.")

    def name_account(self) -> None:
        account = self._selected_account_raw()
        if account == "All Accounts":
            messagebox.showinfo("Name Accounts", "Select an account first.")
            return
        current = self.account_names.get(account, "")
        name = simpledialog.askstring("Name Account", f"Display name for {account}", initialvalue=current, parent=self)
        if name is not None:
            self.store.set_account_name(account, name.strip())
            self.refresh()

    def export_csv(self) -> None:
        path = filedialog.asksaveasfilename(title="Export Transactions", defaultextension=".csv", filetypes=[("CSV files", "*.csv")])
        if not path:
            return
        import csv

        with open(path, "w", encoding="utf-8-sig", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(["Date", "Type", "Name", "Category", "Account", "Amount", "Bank Category", "Note"])
            for entry in self.entries:
                writer.writerow([entry.date.strftime("%d/%m/%Y"), entry.type, entry.name, entry.category, entry.account, entry.amount, entry.bank_category, entry.note])
        messagebox.showinfo("Export CSV", f"Exported {len(self.entries)} transaction(s).")

    def backup_data(self) -> None:
        source = self.store.db_path
        if not source.exists():
            messagebox.showinfo("Backup", "No Python database has been created yet.")
            return
        path = filedialog.asksaveasfilename(title="Backup Data", defaultextension=".sqlite3", filetypes=[("SQLite database", "*.sqlite3")])
        if not path:
            return
        import shutil

        shutil.copy2(source, path)
        messagebox.showinfo("Backup", "Backup complete.")

    def restore_data(self) -> None:
        path = filedialog.askopenfilename(title="Restore Data", filetypes=[("SQLite database", "*.sqlite3"), ("All files", "*.*")])
        if not path:
            return
        if not messagebox.askyesno("Restore", "Replace the Python tracker database with this backup?"):
            return
        import shutil

        self.store.db_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, self.store.db_path)
        self.refresh()
        messagebox.showinfo("Restore", "Restore complete.")

    def sync_legacy_data(self) -> None:
        if not messagebox.askyesno("Sync Data", "Replace the Python database with the current PowerShell tracker data?"):
            return
        try:
            self.store.replace_from_legacy_json()
            self.refresh()
            messagebox.showinfo("Sync Data", "Python database synced from the current PowerShell tracker data.")
        except Exception as exc:
            messagebox.showerror("Sync Data", str(exc))

    def add_entry(self) -> None:
        dialog = EntryDialog(self, self.store, self.entries, None)
        self.wait_window(dialog)
        if dialog.saved:
            self.refresh()

    def mark_income(self) -> None:
        selected = self.transactions.selection()
        if not selected:
            messagebox.showinfo("Mark Income", "Select one or more paycheck transactions first.")
            return
        for entry_id in selected:
            entry = next((item for item in self.entries if item.id == entry_id), None)
            if not entry:
                continue
            updated = Entry(
                id=entry.id,
                type="Income",
                date=entry.date,
                name=entry.name,
                category="Paycheck",
                account=entry.account,
                amount=entry.amount,
                note=entry.note,
                frequency=entry.frequency,
                goal=entry.goal,
                balance=entry.balance,
                bank_category=entry.bank_category,
                serial=entry.serial,
                source=entry.source,
                import_key=entry.import_key,
            )
            self.store.upsert_entry(updated)
        self.refresh()

    def delete_selected_entries(self) -> None:
        selected = self.transactions.selection()
        if not selected:
            return
        if not messagebox.askyesno("Delete Selected", f"Delete {len(selected)} selected transaction(s)?"):
            return
        for entry_id in selected:
            self.store.delete_entry(entry_id)
        self.refresh()

    def add_recurring_from_selection(self) -> None:
        selected = self.transactions.selection()
        items = [entry for entry in self.entries if entry.id in selected and entry.type in {"Expense", "Bill"}]
        if len(items) < 1:
            messagebox.showinfo("Add Recurring", "Select one or more expense transactions first.")
            return
        latest = max(items, key=lambda entry: entry.date)
        payment = RecurringPayment(
            key=f"manual|{new_id()}",
            name=latest.name,
            category=latest.category,
            account=latest.account,
            amount=latest.amount,
            date=latest.date,
            frequency="Monthly",
            count=len(items),
            manual=True,
        )
        dialog = RecurringDialog(self, self.store, payment)
        self.wait_window(dialog)
        if dialog.saved:
            self.refresh()

    def edit_selected_entry(self) -> None:
        selected = self.transactions.selection()
        if not selected:
            return
        entry = next((item for item in self.entries if item.id == selected[0]), None)
        dialog = EntryDialog(self, self.store, self.entries, entry)
        self.wait_window(dialog)
        if dialog.saved:
            self.refresh()

    def add_goal(self) -> None:
        dialog = GoalDialog(self, self.store, self.goals, None, self.account_names)
        self.wait_window(dialog)
        if dialog.saved:
            self.refresh()

    def edit_selected_goal(self) -> None:
        selected = self.goals_tree.selection()
        if not selected:
            return
        goal = next((item for item in self.goals if item.id == selected[0]), None)
        if not goal:
            return
        dialog = GoalDialog(self, self.store, self.goals, goal, self.account_names)
        self.wait_window(dialog)
        if dialog.saved:
            self.refresh()

    def delete_selected_goal(self) -> None:
        selected = self.goals_tree.selection()
        if not selected:
            return
        goal = next((item for item in self.goals if item.id == selected[0]), None)
        if not goal:
            return
        if messagebox.askyesno("Delete Goal", f"Delete savings goal '{goal.name}'?"):
            self.store.delete_goal(goal.id)
            self.refresh()

    def add_recurring(self) -> None:
        dialog = RecurringDialog(self, self.store, None)
        self.wait_window(dialog)
        if dialog.saved:
            self.refresh()


class EntryDialog(tk.Toplevel):
    def __init__(self, master: TrackerApp, store: TrackerStore, entries: list[Entry], entry: Entry | None):
        super().__init__(master)
        self.store = store
        self.entry = entry
        self.saved = False
        self.title("Edit Entry" if entry else "Add Entry")
        self.configure(bg=BG)
        self.resizable(False, False)
        fields = [
            ("Type", "type"),
            ("Date", "date"),
            ("Name", "name"),
            ("Category", "category"),
            ("Account", "account"),
            ("Amount", "amount"),
            ("Bank Category", "bank_category"),
            ("Note", "note"),
        ]
        self.vars = {}
        for row, (label, key) in enumerate(fields):
            tk.Label(self, text=label, bg=BG).grid(row=row, column=0, sticky="w", padx=10, pady=5)
            var = tk.StringVar()
            self.vars[key] = var
            ttk.Entry(self, textvariable=var, width=46).grid(row=row, column=1, padx=10, pady=5)
        if entry:
            self.vars["type"].set(entry.type)
            self.vars["date"].set(entry.date.strftime("%d/%m/%Y"))
            self.vars["name"].set(entry.name)
            self.vars["category"].set(entry.category)
            self.vars["account"].set(entry.account)
            self.vars["amount"].set(str(entry.amount))
            self.vars["bank_category"].set(entry.bank_category)
            self.vars["note"].set(entry.note)
        else:
            self.vars["type"].set("Expense")
            self.vars["date"].set(date.today().strftime("%d/%m/%Y"))
        controls = tk.Frame(self, bg=BG)
        controls.grid(row=len(fields), column=0, columnspan=2, sticky="e", padx=10, pady=10)
        ttk.Button(controls, text="Save", command=self.save).pack(side="left", padx=4)
        if entry:
            ttk.Button(controls, text="Delete", command=self.delete).pack(side="left", padx=4)
        ttk.Button(controls, text="Cancel", command=self.destroy).pack(side="left", padx=4)

    def save(self) -> None:
        entry = Entry(
            id=self.entry.id if self.entry else new_id(),
            type=self.vars["type"].get().strip() or "Expense",
            date=parse_date(self.vars["date"].get()),
            name=self.vars["name"].get().strip(),
            category=self.vars["category"].get().strip(),
            account=self.vars["account"].get().strip(),
            amount=money(self.vars["amount"].get()),
            bank_category=self.vars["bank_category"].get().strip(),
            note=self.vars["note"].get().strip(),
            import_key=self.entry.import_key if self.entry else "",
            source=self.entry.source if self.entry else "",
            serial=self.entry.serial if self.entry else "",
            balance=self.entry.balance if self.entry else money(0),
        )
        self.store.upsert_entry(entry)
        self.saved = True
        self.destroy()

    def delete(self) -> None:
        if self.entry and messagebox.askyesno("Delete Entry", "Delete this entry?"):
            self.store.delete_entry(self.entry.id)
            self.saved = True
            self.destroy()


class GoalDialog(tk.Toplevel):
    def __init__(self, master: TrackerApp, store: TrackerStore, goals: list[Goal], goal: Goal | None, account_names: dict[str, str]):
        super().__init__(master)
        self.store = store
        self.goal = goal
        self.saved = False
        self.title("Savings Goal")
        self.configure(bg=BG)
        fields = [("Name", "name"), ("Account", "account"), ("Target Amount", "target"), ("Due Date", "date"), ("Mode Save/Send", "mode"), ("Kind Target/Weekly", "kind"), ("Weekly Amount", "weekly"), ("Ongoing true/false", "ongoing"), ("Note", "note")]
        self.vars = {}
        for row, (label, key) in enumerate(fields):
            tk.Label(self, text=label, bg=BG).grid(row=row, column=0, sticky="w", padx=10, pady=5)
            var = tk.StringVar()
            self.vars[key] = var
            ttk.Entry(self, textvariable=var, width=42).grid(row=row, column=1, padx=10, pady=5)
        if goal:
            self.vars["name"].set(goal.name)
            self.vars["account"].set(goal.account)
            self.vars["target"].set(str(goal.target_amount))
            self.vars["date"].set(goal.expected_date.strftime("%d/%m/%Y"))
            self.vars["mode"].set(goal.mode)
            self.vars["kind"].set(goal.goal_kind)
            self.vars["weekly"].set(str(goal.weekly_amount))
            self.vars["ongoing"].set(str(goal.is_ongoing))
            self.vars["note"].set(goal.note)
        else:
            self.vars["date"].set(date.today().strftime("%d/%m/%Y"))
            self.vars["mode"].set("Save")
            self.vars["kind"].set("Target")
            self.vars["ongoing"].set("false")
        controls = tk.Frame(self, bg=BG)
        controls.grid(row=len(fields), column=0, columnspan=2, sticky="e", padx=10, pady=10)
        ttk.Button(controls, text="Save", command=self.save).pack(side="left", padx=4)
        ttk.Button(controls, text="Cancel", command=self.destroy).pack(side="left", padx=4)

    def save(self) -> None:
        goal = Goal(
            id=self.goal.id if self.goal else new_id(),
            name=self.vars["name"].get().strip(),
            account=self.vars["account"].get().strip(),
            target_amount=money(self.vars["target"].get()),
            expected_date=parse_date(self.vars["date"].get()),
            mode=self.vars["mode"].get().strip() or "Save",
            goal_kind=self.vars["kind"].get().strip() or "Target",
            weekly_amount=money(self.vars["weekly"].get()),
            is_ongoing=self.vars["ongoing"].get().strip().lower() in {"true", "yes", "1", "ongoing"},
            note=self.vars["note"].get().strip(),
        )
        self.store.upsert_goal(goal)
        self.saved = True
        self.destroy()


class RecurringDialog(tk.Toplevel):
    def __init__(self, master: TrackerApp, store: TrackerStore, payment: RecurringPayment | None):
        super().__init__(master)
        self.store = store
        self.payment = payment
        self.saved = False
        self.title("Recurring Payment")
        self.configure(bg=BG)
        fields = [("Name", "name"), ("Category", "category"), ("Account", "account"), ("Amount", "amount"), ("Date", "date"), ("Frequency", "frequency")]
        self.vars = {}
        for row, (label, key) in enumerate(fields):
            tk.Label(self, text=label, bg=BG).grid(row=row, column=0, sticky="w", padx=10, pady=5)
            var = tk.StringVar()
            self.vars[key] = var
            ttk.Entry(self, textvariable=var, width=42).grid(row=row, column=1, padx=10, pady=5)
        self.vars["date"].set(date.today().strftime("%d/%m/%Y"))
        self.vars["frequency"].set("Monthly")
        if payment:
            self.vars["name"].set(payment.name)
            self.vars["category"].set(payment.category)
            self.vars["account"].set(payment.account)
            self.vars["amount"].set(str(payment.amount))
            self.vars["date"].set(payment.date.strftime("%d/%m/%Y"))
            self.vars["frequency"].set(payment.frequency)
        controls = tk.Frame(self, bg=BG)
        controls.grid(row=len(fields), column=0, columnspan=2, sticky="e", padx=10, pady=10)
        ttk.Button(controls, text="Save", command=self.save).pack(side="left", padx=4)
        ttk.Button(controls, text="Cancel", command=self.destroy).pack(side="left", padx=4)

    def save(self) -> None:
        payment = RecurringPayment(
            key=self.payment.key if self.payment else f"manual|{new_id()}",
            name=self.vars["name"].get().strip(),
            category=self.vars["category"].get().strip(),
            account=self.vars["account"].get().strip(),
            amount=money(self.vars["amount"].get()),
            date=parse_date(self.vars["date"].get()),
            frequency=self.vars["frequency"].get().strip() or "Recurring",
            manual=True,
        )
        self.store.upsert_recurring(payment)
        self.saved = True
        self.destroy()
