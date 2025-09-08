# Solar2D Client (Lua)

## Run
- Open Solar2D **Simulator** and select this `solar2d-client/` folder.
- Ensure your backend is running at `http://localhost:8080` (or change `BASE` and `WSURL` in `main.lua` to your LAN IP).

## Flow (buttons)
1. **Login** → creates/returns a player and token
2. **Open WebSocket** → connects to `ws://.../ws`
3. **Save Progress** → posts a random level/xp; backend broadcasts over WS
4. **Broadcast Test** → asks server to broadcast an arbitrary payload

## Notes
- If the websocket plugin isn't installed, the app continues with HTTP-only.
- To test on a device, replace `localhost` with your dev machine IP in `main.lua`.
