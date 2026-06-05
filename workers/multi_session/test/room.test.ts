import { describe, expect, it } from "vitest";
import { SELF } from "cloudflare:test";

describe("multi-session room contract", () => {
  it("creates a room and exposes public metadata", async () => {
    const create = await SELF.fetch("https://spotube.test/rooms", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "Host" }),
    });

    expect(create.status).toBe(200);
    const room = await create.json<{
      roomId: string;
      code: string;
      token: string;
      ownerToken: string;
      memberId: string;
    }>();

    expect(room.roomId).toBeTruthy();
    expect(room.code).toMatch(/^[A-Z0-9]{6}$/);
    expect(room.token).toBe(room.ownerToken);
    expect(room.memberId).toBeTruthy();

    const metadata = await SELF.fetch(
      `https://spotube.test/rooms/${room.code}`,
    );
    expect(metadata.status).toBe(200);
    await expect(metadata.json()).resolves.toMatchObject({
      roomId: room.roomId,
      code: room.code,
      members: 1,
    });
  });

  it("joins guests with separate member tokens", async () => {
    const create = await SELF.fetch("https://spotube.test/rooms", {
      method: "POST",
      body: JSON.stringify({ name: "Host" }),
    });
    const room = await create.json<{ code: string; memberId: string }>();

    const join = await SELF.fetch(
      `https://spotube.test/rooms/${room.code}/join`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "Guest" }),
      },
    );
    expect(join.status).toBe(200);

    const guest = await join.json<{ token: string; memberId: string }>();
    expect(guest.token).toBeTruthy();
    expect(guest.memberId).not.toBe(room.memberId);

    const metadata = await SELF.fetch(
      `https://spotube.test/rooms/${room.code}`,
    );
    await expect(metadata.json()).resolves.toMatchObject({ members: 2 });
  });

  it("does not leave ghost members after an explicit leave event", async () => {
    const create = await SELF.fetch("https://spotube.test/rooms", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "Host" }),
    });
    const room = await create.json<{ code: string }>();

    const join = await SELF.fetch(
      `https://spotube.test/rooms/${room.code}/join`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "Guest" }),
      },
    );
    const guest = await join.json<{ token: string }>();

    const ws = new WebSocket(
      `wss://spotube.test/rooms/${room.code}/ws?token=${guest.token}`,
    );

    await new Promise<void>((resolve, reject) => {
      ws.addEventListener("open", () => resolve(), { once: true });
      ws.addEventListener("error", () => reject(new Error("websocket failed")), {
        once: true,
      });
    });

    ws.send(JSON.stringify({ type: "leave", data: null }));
    ws.close();

    await new Promise((resolve) => setTimeout(resolve, 0));

    const metadata = await SELF.fetch(
      `https://spotube.test/rooms/${room.code}`,
    );
    await expect(metadata.json()).resolves.toMatchObject({ members: 1 });
  });
});
