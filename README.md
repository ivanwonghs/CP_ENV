# CP-Env Research Extension: Additive Test-Result Retrieval (ATR)

> **Research extension of the original CP-Env.** This repository builds on the official [SPIRAL-MED/CP_ENV codebase](https://github.com/SPIRAL-MED/CP_ENV) at pinned source commit `6c33121d96baf610c9c5b15bf3429129555e5acb` and the paper [*CP-Env: Evaluating Large Language Models on Clinical Pathways in a Controllable Hospital Environment*](https://arxiv.org/abs/2512.10206) (Zhu et al., 2025). The original clinical pathway is extended; the evaluator remains unchanged. This fork adds **Additive Test-Result Retrieval (ATR)** and an internal FHIR R4 shadow event store. It is not the authors’ official repository or an exact reproduction of their paper experiments.
>
> **At a glance:** ATR preserves the original specialist record, appends the names of completed tests with a retrieval cue, and enables tools on the opening specialist turn when prior tests exist. Safe report matching resolves exact names or a limited set of aliases. FHIR R4 resources can separately record case events, but **the ATR index is built from CP-Env’s existing records, not retrieved from FHIR**. The historical measured result used ATR and FHIR event capture together, so it does not isolate FHIR’s effect.
>
> **Evidence status:** one exploratory 101-case paired run using DeepSeek for patient, doctor and judge reported DR@3 of 54.46% for the local flags-off baseline and 85.15% for the ATR bundle (+30.69 percentage points). This was not a direct comparison with the pinned official checkout; possible reference-answer exposure, evaluator fallbacks, and invalid IC values limit interpretation. These results are preliminary, not clinical evidence.

The original paper is the source benchmark and should be cited when this repository is used; its BibTeX entry is provided under [Citation](#citation).

<p align="center">
<img src="assets/appetizer.png" width="50%" alt="CP-Env Overview">
</p>

## Contents

- [Introduction](#introduction)
- [Getting Started](#getting-started)
  - [Installation](#1-installation)
  - [Running the Simulation](#2-running-the-simulation)
  - [Evaluation](#3-evaluation)
  - [Windows workflow launcher](#windows-workflow-launcher)
  - [ATR method and FHIR event memory](#atr-method-and-fhir-event-memory)
- [Research changes and findings](#research-changes-and-findings)
- [Metrics](#metrics)
- [Contact Us](#contact-us)
- [Citation](#citation)
  
## Introduction

**CP-Env** represents our attempt to address the critical gap in evaluating LLM-based agents for healthcare applications. While existing medical benchmarks have made valuable contributions, they primarily focus on examination-style knowledge assessment or conversational abilities in isolated patient dialogues, which may not fully capture the complexity of clinical pathways in real-world clinical practice.

In response to these limitations, we develop **CP-Env** as an open-ended, dynamic, agentic simulation hospital environment that enables LLM agents to navigate realistic clinical pathways. Our environment goes beyond traditional QA formats by simulating the complete patient care journey - from initial consultation through diagnosis and treatment. In **CP-Env**, LLM agents assume diverse healthcare roles, interact with simulated patients who accurately report their clinical conditions, and collaborate across multiple hospital departments as they traverse different pathway branches. This design allows us to evaluate not only medical knowledge but also critical capabilities such as tool utilization, pathway-based decision making, and multi-agent coordination that are essential in actual clinical settings.

<p align="center">
<img src="assets/main.png" width="100%" alt="CP-Env Framework">

We hope that **CP-Env** can serve as a more comprehensive evaluation framework that better reflects the adaptive clinical pathways and dynamic decision-making required in modern healthcare delivery.

## Getting Started

### 1. Installation

Clone the repository and install the required dependencies:

```shell
git clone https://github.com/SPIRAL-MED/CP_ENV.git
cd CP_ENV
pip install -r requirements.txt
```

Those commands install the official upstream repository. To use the local research features and launcher below, use this modified workspace instead. To prepare a separate original checkout for launcher source 3, check out commit `6c33121d96baf610c9c5b15bf3429129555e5acb` in a separate clone; do not replace this workspace.

### 2. Running the Simulation

Use `inference.py` to start the simulation. This script launches the Patient Agent and the Doctor Agent to interact through the medical cases. Ensure you have your API keys ready (e.g., OpenAI API key).

```shell
python codes/inference.py \
    --parallel_workers 8\
    --patient_model_name "gpt-oss-120b" \
    --patient_base_url YOUR_BASE_URL \
    --patient_api_key YOUR_API_KEY \
    --doctor_model_name YOUR_MODEL \
    --doctor_base_url YOUR_BASE_URL \
    --doctor_api_key YOUR_API_KEY
```

Add `--doctor_responses_api` flag if your model requires a response API configuration.

### 3. Evaluation

After generating the simulation logs, use `evaluation.py` to compute metrics. This script uses an LLM-based evaluator to score the interactions.

```shell
python codes/evaluation.py \
    --input_file "./outputs/model.jsonl" \
    --output "./outputs/model_evaluation_results.jsonl" \
    --model "gpt-oss-120b" \
    --base_url YOUR_BASE_URL \
    --api_key YOUR_API_KEY \
    --max_workers 4
```

To view statistics without re-running the evaluation API calls:

```shell
python codes/evaluation.py \
    --output "./outputs/model_evaluation_results.jsonl" \
    --stats_only
```

### Windows workflow launcher

Run `full_workflow_executor.cmd` from this workspace. It offers inference plus evaluation, inference only, evaluation of an existing inference file, and offline statistics. It uses system Python 3.12 or 3.13, installs the local pinned requirements into `.python-packages`, and writes unique inference logs and results under this workspace. The first dependency installation and model calls require network access; model calls may incur costs. Enter keys through hidden prompts or use the workspace `.env` (`DEEPSEEK_API_KEY` or `deepseek_apikey` for `https://api.deepseek.com`; other providers need role-specific keys). Do not share credentials, logs, or JSONL files.

Choose a source after choosing an action:

1. **Local baseline**: this modified workspace with the candidate disabled. This is not a verified upstream checkout.
2. **Local ATR + FHIR (default)**: additive test-result retrieval, FHIR event capture, and safe report matching enabled together.
3. **Pinned official original**: provide an existing separate checkout of official commit `6c33121d96baf610c9c5b15bf3429129555e5acb`. The launcher verifies nine workflow and requirements files by SHA-256, ignoring CRLF versus LF, and runs its original source with all optional features off. It does not clone or edit that checkout. Each action runs in a separate Python process; results, logs, credentials and installed dependencies belong to this workspace. Verification covers those files, not a complete checkout or the external environment.
4. **Local ATR without FHIR**: keeps ATR and safe report matching enabled but skips FHIR event capture. This is an ablation condition; its effect must be measured, not assumed.

For comparable runs, manually select the same models, endpoints, case count, limits and other settings each time. The launcher selects the first requested cases; it does not pin the dataset revision or automatically create a paired comparison manifest. It applies runtime output/log path redirection, a write lock, failure checks and, for `deepseek-flash`, disables thinking. These wrapper choices and the local dependency set also apply to the pinned original; it is **not** an unmodified end-to-end paper reproduction. Automatic evaluation is skipped if any selected inference case fails. To include such records, explicitly choose “evaluate existing inference” and allow failed cases; retain and report failures, and review evaluator fallbacks. Statistics alone do not verify score validity.

### ATR method and FHIR event memory

Direct inference now uses ATR with FHIR event capture by default. Pass `--no_fhir_memory` to keep ATR and safe report matching but skip FHIR event capture. Pass `--baseline` to disable ATR and safe matching as well; this runs the local code's baseline path, not a separate upstream checkout. FHIR-enabled runs require `fhirclient==4.2.0`; no FHIR server is needed.

**ATR** retains the original specialist record, appends a bounded completed-test-name index and a `get_info` cue, and enables registered tools on the opening specialist turn when completed tests exist. Report matching uses exact names and a small set of unambiguous textual aliases. Separately, the per-case FHIR R4 event memory records observed events and simulated reports in shadow; the test index is taken from existing simplified records, **not** from FHIR memory. No raw FHIR JSON is sent to models.

As in the original code, direct inference selects one case. The launcher supports a chosen case count and creates unique output files. Baseline and candidate direct output names differ, but direct inference resumes existing files by case ID: move or preserve old results separately before a fresh run or changed settings. Do not mix conditions. Keep models, dataset revision, cases and evaluator settings fixed, and report failed cases.

Generated reports are not independently verified, and the simulator can use the full reference case. The FHIR models validate fields and types, not complete R4 profiles, terminology or clinical correctness. Logs and JSONL can contain sensitive case data and must remain private. This is a research simulation, not a clinical decision system.

## Research changes and findings

This separate section describes this workspace's research additions, not claims by the original authors. The official baseline is [SPIRAL-MED/CP_ENV](https://github.com/SPIRAL-MED/CP_ENV) at `6c33121d96baf610c9c5b15bf3429129555e5acb`. The local starting commit `c2d3c70f32f2da8b94789238aa61db77be3868d0` is seven commits ahead, with the launcher as its net committed addition; the current working tree adds the experimental changes described here. A flags-off local run is therefore a useful **local** comparator, not proof of equivalence to the original.

### What changed and why

- `codes/fhir_memory/` adds per-case, in-memory FHIR R4 event resources and source metadata. Generated reports can be stored before disclosure; disclosure metadata is separate from the exported FHIR Bundle. No raw FHIR JSON is sent to models.
- `codes/pipeline.py`, `codes/utils/run_context.py` and `codes/utils/tools.py` implement ATR, safe report matching and shadow event capture alongside the original simulation. `codes/inference.py` enables the bundle by default and offers `--baseline`. `requirements.txt` adds `fhirclient==4.2.0`.
- `full_workflow_executor.cmd` provides the Windows launcher, output isolation and safety checks described above. `codes/evaluation.py` remains unchanged. The earlier paired experiment compared local configurations, not the separate pinned checkout.
- **Presentation hypothesis:** preserving the original specialist record while adding a compact completed-test index and an explicit retrieval cue may help doctors find relevant evidence without replacing context. ATR combines this with safe name/alias matching and enables real tools on the opening specialist turn when completed reports exist. That opening turn exposes all registered tools, not only `get_info`. The result tests a **bundle**, not an isolated FHIR or retrieval effect.

### Exploratory local comparison: all 13 paper metrics

The paired run in `outputs/retrieval-paired-20261122-022910-2c03c093/` used 101 matched cases from dataset revision `64bb873fe651e1c71cd8b0958104dd911f042872`, comparing local flags-off against ATR with FHIR event capture and safe report matching. DeepSeek was patient, doctor and judge in both arms. Values below are the original evaluator's means as percentages; Δ is candidate minus baseline in percentage points. All 101 records, including failures, are represented. This is not a comparison with an official-checkout run or a reproduction of the paper's scores. ATR without FHIR was not tested in this historical run.

| Metric | Local baseline | Candidate | Δ pp |
|---|---:|---:|---:|
| WC | 87.13 | 98.02 | +10.89 |
| DR@3 | 54.46 | 85.15 | +30.69 |
| DR@5 | 56.44 | 86.14 | +29.70 |
| TP | 81.19 | 82.18 | +0.99 |
| IS | 80.83 | 81.85 | +1.02 |
| LC | 38.81 | 37.03 | −1.78 |
| RC | 96.83 | 99.80 | +2.97 |
| IC | 28.63 | 25.95 | −2.68 |
| RU | 72.97 | 95.90 | +22.93 |
| PS | 99.01 | 100.00 | +0.99 |
| TI | 40.69 | 35.94 | −4.75 |
| ED | 54.36 | 55.35 | +0.99 |
| FP | 68.32 | 85.15 | +16.83 |

WC: workflow completion; DR@3/DR@5: diagnosis recall at 3/5; TP: triage performance; IS: information sufficiency; LC: logic coherence; RC: record compliance; IC: inspection/test IoU; RU: result utilization; PS: privacy safeguarding; TI: treatment individualization; ED: empathetic dialogue; FP: follow-up prognosis management. The original evaluator implements these through a mixture of rules and LLM-judged scores.

**Interpretation and limitations:** 87 cases completed in both arms; 12 failed only in the baseline, one only in the candidate and one in both. For DR@3, 33 cases improved and two worsened; a paired bootstrap gives a 95% difference interval of +20.79 to +40.59 pp. This exploratory interval does not include repeated-generation or judge variability. The selected slice was previously piloted on one case, and fixed arm order permits provider/time drift. Shared DeepSeek roles introduce shared-model bias; the paper specifies GPT-OSS-120B for the patient simulator, while its judge model was not established here.

One candidate IC result was **160%**, an impossible overlap value produced by the unchanged evaluator. An audit also found impossible judge-produced overlap counts in 12 baseline and 5 candidate cases, so IC is unreliable in both arms and has not been silently corrected. The evaluator may also substitute fallback scores after errors and assess only the first specialist dialogue. Its RU reflects requested test names, not demonstrated comprehension. Simulated test generation receives the full reference case, including the final diagnosis; reports accessible through `get_info` or MDT may therefore reveal answer information in both arms. A literal diagnosis-string check found it in retrieved reports in 26 baseline versus 44 candidate cases, but cannot establish semantic leakage or causality. Report all metrics, failures and limitations; do not infer clinical effectiveness or a causal improvement from this single bundled comparison. The source and launcher have since been simplified; the historical result has not been rerun on this revision.

## Metrics

CP-Env employs a comprehensive Agent Evaluation Framework that systematically evaluates LLM capabilities within agentic hospital settings through three progressive dimensions:

- **Clinical Efficacy**: Evaluates whether the agent can successfully resolve medical problems and optimize patient outcomes through accurate diagnosis and therapeutic interventions.
- **Process Competency**: Assesses whether the agent demonstrates sound and logically coherent problem-solving processes throughout the healthcare workflow.
- **Professional Ethics**: Examines whether the agent maintains ethical compliance and delivers humanistic care in patient interactions.

## Contact Us

If you are interested in our project and would like to join us, feel free to send an email to [xiaofan.zhang@sjtu.edu.cn](mailto:xiaofan.zhang@sjtu.edu.cn).

## Citation

If you find this work useful, please cite our paper.

```
@article{zhu2025cp,
  title={CP-Env: Evaluating Large Language Models on Clinical Pathways in a Controllable Hospital Environment},
  author={Zhu, Yakun and Huang, Zhongzhen and Feng, Qianhan and Mu, Linjie and Gu, Yannian and Zhang, Shaoting and Dou, Qi and Zhang, Xiaofan},
  journal={arXiv preprint arXiv:2512.10206},
  year={2025}
}
```
