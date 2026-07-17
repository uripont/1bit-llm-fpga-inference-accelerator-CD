# Project presentation

Reveal.js presentation for the 1-bit LLM FPGA inference accelerator project. React owns the deck structure, and every slide is an individual component under `src/slides/`.

## Run locally

From this directory:

```sh
npm install
npm run dev
```

Then open the URL printed by Vite. Use the arrow keys to navigate and press `S` to open Reveal.js speaker notes.

## Production build

```sh
npm run build
npm run preview
```

The static site is written to `dist/`. `vite.config.js` uses a relative base path, so the build can be published below the repository path on GitHub Pages. A later Pages workflow can upload `presentation/dist/` as its static artifact.

## Evidence used

Project claims and numbers come from the committed reports and their raw results:

- `../docs/01-bonsai-bottleneck-benchmark.pdf`
- `../docs/02-bonsai-accelerator-hardware-blueprint.pdf`
- `../docs/03-bonsai-accelerator-implementation-evaluation.pdf`
- `../results/tier1_llama_cpp_benchmark/`
- `../results/tier2_explicit_runner/`
- `../results/tier3_neorv32_cycle_kernels/`
- `../results/proposal_a_evaluation/`
- `../results/proposal_b_evaluation/`
- `../results/gowin_synthesis/`

External motivation slides link directly to the Taalas HC1 product page, the Talos V2 project, Sipeed board documentation, and the Kimi K3 launch post. Taalas and Kimi figures are explicitly labeled as company-reported claims in the deck.

The board photograph comes from the official Sipeed wiki. The Computer Modern Serif webfonts are derived from CMU Serif and distributed under the SIL Open Font License; attribution is preserved in `public/fonts/LICENSE.txt`.
