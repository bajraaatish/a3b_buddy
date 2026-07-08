# Wiring requests

Agents that may not touch `.xcodeproj`, `Info.plist`, entitlements, or `A3BBuddy/App/*` (GPT-1, FLASH-1) drop a short note here — `<agent>.md` — describing anything that must be hooked up at app init or in the project file. FABLE-1 applies these at merge time.

Format: what to wire, where (file:symbol), why, and how to verify it worked.
