# Release checklist

- [ ] All CI workflows green (iOS, Backend & Admin) on the release commit
- [ ] `docs/openapi.json` regenerated; app models still decode (StreameroCore contract tests)
- [ ] Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `ios/project.yml`
- [ ] Physical-device checklist (IMPLEMENTATION_STATUS.md) passed on at least one iPhone
- [ ] Backup taken and restore drill done on staging; migrations applied on staging
- [ ] Secrets rotated if anyone left the team; `npm audit --omit=dev` clean
- [ ] Tag `vX.Y.Z` → CI attaches the unsigned IPA to the GitHub Release (Feather users)
- [ ] Signed build: `scripts/export-signed-ipa.sh` (Ad Hoc / TestFlight) when signing assets are available
- [ ] Release notes: features, known limitations, minimum server version
