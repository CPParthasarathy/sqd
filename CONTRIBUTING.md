# Contributing to SQD Firmware

1. Update local `main`.
2. Create a short-lived branch using the B2.2 naming policy.
3. Make one coherent change.
4. Build and test the affected scope.
5. Use Conventional Commit messages.
6. Push the branch and open a pull request.
7. Complete the self-review checklist.
8. Squash merge only after all acceptance conditions pass.
9. Delete the merged branch.

```powershell
git switch main
git pull --ff-only origin main
git switch -c feat/<wbs-or-issue>-<short-description>
```

Commit format:

```text
<type>[optional scope][!]: <imperative description>
```

Before opening a pull request, verify the intended build, relevant tests, absence of generated files and secrets, documentation, traceability and version impact.

The authoritative rules are in `docs/phase-b/B2.2_Source_Control_and_Versioning_Policy.md`.
