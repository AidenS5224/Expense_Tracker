from .storage import TrackerStore
from .ui import TrackerApp


def main() -> None:
    store = TrackerStore.default()
    store.initialize()
    app = TrackerApp(store)
    app.mainloop()
