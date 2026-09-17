"""Canales de aviso: consola/log, Telegram y correo (SMTP)."""

from __future__ import annotations

import logging
import smtplib
import ssl
from abc import ABC, abstractmethod
from email.message import EmailMessage
from typing import Iterable

log = logging.getLogger(__name__)


class Notifier(ABC):
    name = "base"

    @abstractmethod
    def send(self, title: str, body: str) -> None: ...


class ConsoleNotifier(Notifier):
    name = "console"

    def send(self, title: str, body: str) -> None:
        log.warning("AVISO | %s | %s", title, body.replace("\n", " · "))


class TelegramNotifier(Notifier):
    """Envía mensajes con la Bot API de Telegram (método ``sendMessage``)."""

    name = "telegram"

    def __init__(self, bot_token: str, chat_id: str, timeout_s: float = 15.0) -> None:
        if not bot_token or not chat_id:
            raise ValueError("Telegram requiere bot_token y chat_id")
        self.bot_token = bot_token
        self.chat_id = str(chat_id)
        self.timeout_s = timeout_s

    def send(self, title: str, body: str) -> None:
        import requests  # dependencia transitiva de locationsharinglib

        url = f"https://api.telegram.org/bot{self.bot_token}/sendMessage"
        resp = requests.post(
            url,
            json={"chat_id": self.chat_id, "text": f"{title}\n{body}"},
            timeout=self.timeout_s,
        )
        resp.raise_for_status()
        payload = resp.json()
        if not payload.get("ok"):
            raise RuntimeError(f"Telegram rechazó el mensaje: {payload}")


class EmailNotifier(Notifier):
    name = "email"

    def __init__(
        self,
        host: str,
        port: int,
        username: str,
        password: str,
        sender: str,
        recipients: Iterable[str],
        use_starttls: bool = True,
        timeout_s: float = 20.0,
    ) -> None:
        self.host, self.port = host, int(port)
        self.username, self.password = username, password
        self.sender = sender
        self.recipients = [r for r in recipients if r]
        self.use_starttls = use_starttls
        self.timeout_s = timeout_s
        if not self.recipients:
            raise ValueError("Email requiere al menos un destinatario")

    def send(self, title: str, body: str) -> None:
        msg = EmailMessage()
        msg["Subject"] = title
        msg["From"] = self.sender
        msg["To"] = ", ".join(self.recipients)
        msg.set_content(body)
        context = ssl.create_default_context()
        if self.use_starttls:
            with smtplib.SMTP(self.host, self.port, timeout=self.timeout_s) as smtp:
                smtp.starttls(context=context)
                if self.username:
                    smtp.login(self.username, self.password)
                smtp.send_message(msg)
        else:
            with smtplib.SMTP_SSL(self.host, self.port, context=context, timeout=self.timeout_s) as smtp:
                if self.username:
                    smtp.login(self.username, self.password)
                smtp.send_message(msg)


def broadcast(notifiers: Iterable[Notifier], title: str, body: str) -> int:
    """Envía por todos los canales; devuelve cuántos fallaron (nunca lanza)."""
    failures = 0
    for n in notifiers:
        try:
            n.send(title, body)
        except Exception:  # noqa: BLE001 - un canal caído no debe tumbar al resto
            failures += 1
            log.exception("Fallo enviando aviso por %s", n.name)
    return failures
