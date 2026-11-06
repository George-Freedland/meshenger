# Security

Meshenger hasn't had an independent security audit yet. Please don't rely on it in situations where your safety depends on it.

## Reporting a vulnerability

Please report security problems privately rather than in a public issue:

- use **Report a vulnerability** on the repository's [Security tab](https://github.com/George-Freedland/meshenger/security), or
- email **george.meshenger@gmail.com** with "Security" in the subject.

Include what you found, how to reproduce it, and which versions and platforms are affected. You'll get a reply within a few days. Once a fix ships, you're welcome to be credited.

## In scope

- Reading, altering or forging messages, files, calls or posts, including from a relay in the middle.
- Impersonating another identity, or getting a device to accept a forged announcement or location.
- Crashing or taking over a device with crafted Bluetooth packets.
- Data leaving a device in ways [PRIVACY.md](PRIVACY.md) says it doesn't.

## Known limits

These are part of the design, and listed in the privacy policy:

- People nearby can see your nickname, your public key and that you're around. Invisible mode stops announcing you.
- Relays can see which public keys a message is from and to, but not what's in it.
- Global posts, your website, and your location (if you turn on sharing) are public by design.
