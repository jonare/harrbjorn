# CLAUDE.md — harrbjorn

Isolert rootless Podman-sandbox for autonome agenter (Claude Code, pi). Én CLI
(`harrbjorn`), to usecases (`code` / `security`), delt isolasjonskjern i
`lib/sandbox.sh`, tynne wrappers (`run-code.sh`, `run-pentest.sh`) og ett bilde
per usecase.

## Bilder må bygges på nytt ved endringer

`build_image` i `lib/sandbox.sh` bygger **bare** hvis bildet mangler, med mindre
`--rebuild` gis. Endringer i kilde som bakker inn i bildene — `code/sbx-init.sh`,
`code/Dockerfile`, `pentest/Dockerfile`, `proxy/Dockerfile` — **propagerer ikke**
til allerede bygd bilder. Et eksisterende bilde er stale så lenge det ikke bygges
på nytt, selv om kilde har endret seg.

Konsekvens:

- `harrbjorn/pentest:latest` bygger `FROM harrbjorn/code:latest`, så endringer i
  code-bildet (f.eks. `code/sbx-init.sh`) plukkes opp av pentest **kun** når pentest
  bygges på nytt *etter* code.
- Hvis du endrer kode som bakker inn i bildene, bygg **begge** bildene på nytt
  (i riktig rekkefølge: code først, deretter pentest), eller bruk `--rebuild`:

  ```
  harrbjorn code --rebuild        # bygger code:latest
  harrbjorn security --rebuild    # bygger code:latest + pentest:latest
  ```

Eksempel på feilen dette forårsaker: Burp-CA auto-install (kjenner du igjen via
`>> Burp CA installed from …/cert` på stderr) ble lagt inn i `code/sbx-init.sh`,
code-bildet ble bygd, men det stale pentest-bildet gjentegnet ikke — `code`-modus
fungerte, `security`-modus ga feil med «self-signed certificate» på `curl` gjennom
`-p`.

## Testdekning og red-green

Koden skal være dekket av testcases — ikke la nye endringer eller fixer stå uten
test. Ved utvikling bruker du **red-green** (test først):

1. **Red:** Skriv en test som feiler mot den oppfølgende endringen/feilen.
2. **Green:** Skriv så lite kode som mulig for at testen passerer — minimalt, ikke for mye.
3. (Ren: refaktor mens alt fortsatt er grønt.)

Testene ligger i `tests/` og kjøres som bash (ingen testrunner-rammeverk):

- Enhetstester er self-contained (bash + python3, ingen podman/nettverk) — kjør
  f.eks. `bash tests/test-proxy-policy.sh`.
- Integrasjonstester krever podman + KVM — `bash tests/test-proxy-integration.sh`.

En endring er ikke ferdig før den korrespondende testen passerer; en ny bug som
fikses skal fange bug-en først (red) og deretter låse den (green).
