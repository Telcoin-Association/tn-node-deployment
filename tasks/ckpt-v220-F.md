status: done
agent: F (fix round: reinstall hint S1-S4)
completed sections:
- read the code: verify_manifest, run_update bootstrap, test helpers from 2afa908
- S1: update-scripts.sh verify_manifest list now NOSIG|EXPKEYSIG (line 672); comment 644-651 says why REVKEYSIG gets none
- S2: run_update: local nohint="" (1012); nohint=nohint where keys=$BOOT_KEYS (1045-1047); verify_manifest ... "$keys" "" "$nohint" (1050)
- S3 tests: revoked -> "0 0"; expired beside good -> "1 1"; bootstrap foreign -> "0 0"; bootstrap success names the signing key;
  EXPSIG and ERRSIG(4) via gpgv stand-in ($T/gpgv-stub, gpgv_says) -> "0 0".
- mutations (scratchpad mutA/mutB): REVKEYSIG back -> only the revoked check FAILs; bootstrap nohint removed -> only the bootstrap check FAILs.
- captures: scratchpad cap-expired.txt, cap-revoked.txt
- S4: bash -n, check-bash32, shellcheck clean; bash 5 and /bin/bash: updater_manifest 303/0, install 113/0, cut_release 119/0;
  release_scripts 167/0; fake gpg 302/0 (1 skip: real OpenPGP); docker bash:3.2 299/0 (2 skips: real OpenPGP, git 1187ddb)
