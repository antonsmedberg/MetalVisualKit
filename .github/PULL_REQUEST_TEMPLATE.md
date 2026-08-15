## Summary

<!-- What changed, and why? Keep the scope focused. -->

## Verification

<!-- List the exact commands and destinations you used. -->

- [ ] `make parity`
- [ ] `make build`
- [ ] `make test`
- [ ] `make demo`
- [ ] `make lint`
- [ ] `make docs`
- [ ] `make swift6` (advisory; explain if it was not run)
- [ ] Media checks relevant to this change

## Evidence

<!-- Add screenshots for visible UI changes. State simulator versus device. -->

- Environment:
- Simulator or physical device:
- Hardware-only behaviour verified: yes / no / not applicable

## Checklist

- [ ] The change is limited to one coherent concern.
- [ ] Tests cover new or corrected behaviour.
- [ ] Public API and contributor documentation are updated where needed.
- [ ] `CHANGELOG.md` is updated for user-visible changes.
- [ ] Swift and Metal struct layouts remain in sync.
- [ ] Generated Xcode files match `project.yml` when project metadata changed.
- [ ] No credentials, DerivedData, `.xcresult`, `xcuserdata` or conflict copies are included.
- [ ] Claims distinguish simulator evidence from physical-device evidence.
