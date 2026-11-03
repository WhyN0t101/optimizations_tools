These scripts simulate Windows (registry, hosts file, scheduled tasks, power plans, apps) so the apply, health check and
revert logic can be exercised without a Windows machine. They were written for PowerShell 7 on Linux.
Paths at the top of each file (`/tmp/sim`, `/mnt/user-data/outputs/FocusedTweaks.ps1`) need adjusting for your machine.

- harness.ps1: apply, healthy check, injected faults, revert with an exact comparison of the registry.
- harness_new.ps1: desktop icons, power plan GUIDs, restore point retry.
- only_test.ps1: the -Only switch with Start pins and Quick Assist.
- harness_union.ps1: partial runs keep earlier health check expectations.
- robust.ps1: registry file parser edge cases. dry.ps1: dry run with stubs.
