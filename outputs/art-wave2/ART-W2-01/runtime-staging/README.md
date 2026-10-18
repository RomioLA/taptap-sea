# ART-W2-01 mechanical runtime staging

Staged 88 confirmed source PNG locations into 92 optimized PNG candidates (four ART-W1-01 islands have both 768 and 1024 variants). Source set: `assets/generated/highspec/ART-W1-01..05/`, W1-05 files already in `outputs/art-wave1/ART-W1-05/candidates/`, and all `assets/image/ART-W1-02_*.png` Maker originals. The 14 duplicated W1-02 locations retain separate rows and destination names in the staging map.

All staging candidates preserve complete visible-alpha content, centered at max 88% of the requested canvas with aspect ratio maintained; resizing uses premultiplied RGBa Lanczos. No heuristic color cleanup was applied. Per-file original/staged dimensions, alpha bounds and pixel counts, SHA256, byte sizes, savings, budget limit, and soft-overbudget flag are in `staging-map.json`. Budgets: islands 500,000 B; ships/world environment 300,000 B; ordinary small assets 250,000 B; bottom panel 400,000 B.

The package byte budget is not summed across this staging option set because island variants repeat the same originals. Seven island options exceed 500,000 B and the caustic texture exceeds 250,000 B; all are flagged per their actual category budgets. All archive copies passed SHA256 validation: 77 PNG originals and 3 `.meta` sidecars. `relocation-plan.json` is **PARTIAL**: its blocking list contains the 80 explicit originals still under `assets/`; already-archived `outputs/` files are excluded. No source was removed.

Priority candidates: `assets/generated/highspec/ART-W1-01/ship_fishing_sloop_A.png` → `ship_fishing_sloop_A__640x427.png`; `island_sandy_green_cove.png` → 768 and 1024 variants; W1-02 `seabird_glide.png`, `seabird_dive.png`, `ripple_small.png`, and `bigfish_splash_roaming.png` → 384/256 candidates. Formal input archive paths are `outputs/art-wave1/ART-W1-01/candidates/` and `outputs/art-wave1/ART-W1-02/candidates/`.

Run `prepare_staging.py` with the configured Python executable and Pillow 12.3 to regenerate the maps and candidates. It only creates/overwrites staging outputs and verified archive copies; it never removes files.
