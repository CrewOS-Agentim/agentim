"""Slack via Socket Mode: no public URL needed. Answers DMs and @mentions, in threads."""

import logging
import re

from . import Channel

log = logging.getLogger("agentim.slack")


def parse_event(event, bot_user_id=None):
    """Returns (chat_id, user_id, text) for a message the bot should answer, else None.

    chat_id is "<channel>|<thread_ts>" so replies stay in the thread.
    """
    kind = event.get("type")
    if event.get("bot_id") or event.get("subtype") or not event.get("user"):
        return None
    if kind == "message" and event.get("channel_type") != "im":
        return None  # in channels, only answer @mentions
    if kind not in ("message", "app_mention"):
        return None
    text = event.get("text", "")
    if bot_user_id:
        text = text.replace(f"<@{bot_user_id}>", "")
    text = re.sub(r"<@[A-Z0-9]+>", "", text).strip() if kind == "app_mention" else text.strip()
    thread = event.get("thread_ts") or (event.get("ts") if kind == "app_mention" else "")
    return f"{event['channel']}|{thread}", event["user"], text


class Slack(Channel):
    name = "slack"

    def __init__(self, gateway, bot_token, app_token):
        super().__init__(gateway)
        from slack_sdk import WebClient

        self.web = WebClient(token=bot_token)
        self.app_token = app_token
        self.bot_user_id = None

    @staticmethod
    def _target(chat_id):
        channel, _, thread = chat_id.partition("|")
        return channel, thread or None

    def send_text(self, chat_id, text):
        channel, thread = self._target(chat_id)
        self.web.chat_postMessage(channel=channel, thread_ts=thread, text=text, mrkdwn=True)

    def send_media(self, chat_id, kind, data, filename):
        channel, thread = self._target(chat_id)
        self.web.files_upload_v2(channel=channel, thread_ts=thread, content=data, filename=filename,
                                 title=f"Agent Tim's {kind}")

    def run(self):
        from slack_sdk.socket_mode import SocketModeClient
        from slack_sdk.socket_mode.request import SocketModeRequest
        from slack_sdk.socket_mode.response import SocketModeResponse

        try:
            self.bot_user_id = self.web.auth_test()["user_id"]
        except Exception as e:
            self.status = f"error: {e}"
            log.error("slack: bad bot token? %s", e)
            return

        client = SocketModeClient(app_token=self.app_token, web_client=self.web)

        def listener(socket_client, req: SocketModeRequest):
            socket_client.send_socket_mode_response(SocketModeResponse(envelope_id=req.envelope_id))
            if req.type != "events_api":
                return
            parsed = parse_event(req.payload.get("event", {}), self.bot_user_id)
            if parsed:
                self.deliver_async(*parsed)

        client.socket_mode_request_listeners.append(listener)
        client.connect()
        self.status = "connected"
        log.info("slack: connected")
