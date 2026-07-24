# Bouneksha

## Build
gem build boukensha.gemspec
gem install boukensha-0.13.0.gem
# Player profiles

Boukensha keeps shared configuration in `BOUKENSHA_DIR` and player state in
`BOUKENSHA_DIR/profiles/<name>`. Every launch must select an existing profile:

```sh
boukensha --list-profiles
boukensha --profile Andrew
BOUKENSHA_PROFILE=Dummy boukensha
```

Create a profile directory and `profile.yaml` before launching it:

```yaml
player:
  name: Dummy
  password_env: MUD_PASSWORD_DUMMY
  persona: cautious-explorer

overrides:
  task:
    provider:
    model:
  mud:
    host:
    port:
```

Keep `MUD_PASSWORD_DUMMY` and provider keys in the shared `.env`; never put a
password in `profile.yaml`. Move existing `knowledge.sqlite3`, `sessions/`,
`journal/`, `manager/`, and `telnet/` into the current player's profile.
Shared `settings.yaml`, `.env`, `models/`, and `prompts/` remain at the root.
