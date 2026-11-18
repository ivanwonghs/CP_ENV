# Run from any directory; Enter selects the displayed default; Ctrl+C cancels.
# Python output is filtered because it can contain keys or patient data.
$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
$python = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
$envNames = @('CP_WORKFLOW_CONFIG', 'CP_PATIENT_KEY', 'CP_DOCTOR_KEY', 'CP_EVALUATOR_KEY')
$savedEnvironment = @{}
foreach ($name in $envNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

function Read-Default([string]$Label, [string]$Default) {
    $value = Read-Host "$Label [$Default]"
    if ($null -eq $value) { throw 'Input cancelled.' }
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}
function Read-Choice([string]$Label, [string]$Default, [string[]]$Allowed) {
    while ($true) {
        $value = Read-Default $Label $Default
        if ($Allowed -contains $value) { return $value }
        Write-Host ('Choose one of: ' + ($Allowed -join ', '))
    }
}
function Read-Positive([string]$Label, [int]$Default) {
    while ($true) {
        $value = Read-Default $Label ([string]$Default)
        $number = 0
        if ([int]::TryParse($value, [ref]$number) -and $number -gt 0) { return $number }
        Write-Host 'Enter a positive integer.'
    }
}
function Read-Model([string]$Label, [string]$Default) {
    while ($true) {
        $value = Read-Default $Label $Default
        if ($value -match '^[A-Za-z0-9][A-Za-z0-9._-]*$' -and
            $value -notmatch '\.\.' -and $value -notmatch '[. ]$' -and $value.Length -le 80) { return $value }
        Write-Host 'Use a safe model ID (letters, digits, dot, underscore or hyphen; no slash, backslash, traversal, or trailing dot).'
    }
}
function Read-EvaluatorModel([string]$Label, [string]$Default) {
    while ($true) {
        $value = Read-Default $Label $Default
        if ($value.Length -le 200 -and
            $value -match '^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$' -and
            $value -notmatch '\.\.' -and $value -notmatch '(^|/)[^/]*\.$' -and
            $value -notmatch '\.jsonl?$') { return $value }
        Write-Host 'Enter a model ID, e.g. deepseek-flash or provider/model; not a file path or JSON/JSONL filename.'
    }
}
function Read-BaseUrl([string]$Label, [string]$Default) {
    while ($true) {
        $value = Read-Default $Label $Default
        $uri = $null
        if ($value -notmatch '[\s\\?#]' -and
            [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -and
            $uri.Scheme -in @('http', 'https') -and $uri.Host -and
            -not $uri.UserInfo -and $value -match '^https?://[^/@]+(?:/|$)') { return $value }
        Write-Host 'Enter an absolute http(s) base URL with a host, e.g. https://api.example.com/v1 or http://localhost:8000/v1; no credentials, query, or fragment.'
    }
}
function Read-Key([string]$Label) {
    $secure = Read-Host $Label -AsSecureString
    if ($null -eq $secure -or $secure.Length -eq 0) { throw 'No API key entered; cancelled.' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); $secure.Dispose() }
}
function Read-SelectedKey([string]$Role, [string]$Default, [bool]$HasPatient, [bool]$HasDoctor) {
    $choices = @('1')
    $label = "$Role key: 1=new key"
    if ($HasPatient) { $choices += '2'; $label += ', 2=reuse patient key' }
    if ($HasDoctor) { $choices += '3'; $label += ', 3=reuse doctor key' }
    $choice = Read-Choice $label $Default $choices
    switch ($choice) {
        '2' { return $env:CP_PATIENT_KEY }
        '3' { return $env:CP_DOCTOR_KEY }
        default { return (Read-Key "Enter $Role API key (hidden)") }
    }
}
function Resolve-WorkspacePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A file path is required.' }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $Path))
}
function Resolve-EvaluationOutput([string]$Path) {
    if ($Path -split '[\\/]' -contains '..') { throw 'Evaluation output cannot contain path traversal.' }
    $resolved = Resolve-WorkspacePath $Path
    $outputs = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'outputs')).TrimEnd([char[]]'\/')
    if (-not $resolved.StartsWith($outputs + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetExtension($resolved) -ine '.jsonl' -or
        $resolved.Substring([IO.Path]::GetPathRoot($resolved).Length).Contains(':')) {
        throw 'Evaluation output must be a .jsonl file under the workspace outputs directory.'
    }
    $parent = Split-Path -Parent $resolved
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Evaluation output parent directory does not exist.' }
    # Check every existing ancestor, including workspace and outputs, for junctions/symlinks.
    $current = $resolved
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Evaluation output cannot use a link or reparse-point directory.'
        }
        $next = Split-Path -Parent $current
        if (-not $next -or $next -eq $current) { break }
        $current = $next
    }
    return $resolved
}
function Backup-Artifact([string]$Path, [bool]$Move) {
    $backup = $Path + '.pre-executeCommand-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
    if ($Move) { Move-Item -LiteralPath $Path -Destination $backup }
    else { Copy-Item -LiteralPath $Path -Destination $backup }
    Write-Host 'Existing artifact preserved in a uniquely named backup.'
}

# Only fixed code is piped to Python. Options and keys travel in the process
# environment, never interpolated into code or exposed in an OS command line.
$runner = @'
import contextlib
import io
import json
import math
import os
import re
import runpy
import subprocess
import sys

cfg = json.loads(os.environ['CP_WORKFLOW_CONFIG'])
action = cfg['action']
sys.path.insert(0, os.path.abspath('codes'))
categories = {'AuthenticationError', 'BadRequestError', 'APIConnectionError',
              'APITimeoutError', 'RateLimitError', 'InternalServerError',
              'JSONDecodeError', 'KeyError', 'IndexError', 'TypeError',
              'AttributeError', 'ModuleNotFoundError', 'ImportError',
              'SyntaxError', 'FileNotFoundError', 'PermissionError',
              'ValueError', 'OSError', 'RuntimeError'}
captured = io.StringIO()
api_errors = []
api_successes = []
failure_events = []
resumed = False
stage = 'SETUP'

def record_failure(stage_name, exc):
    name = type(exc).__name__
    failure_events.append((stage_name, name if name in categories else 'OtherError'))

def captured_text():
    try:
        text = captured.getvalue()
        if not isinstance(text, str):
            raise TypeError('Invalid capture')
        return text
    except Exception:
        raise RuntimeError('Invalid capture') from None

def inference_diagnostic(items):
    failed = [item for item in items if item.get('process_success') is False]
    if not failed:
        return None
    if len(failed) != 1 or len(items) != 1 or failure_events:
        return 'INCOMPLETE'
    item = failed[0]
    dialogues = item.get('doctor_patient_diaglogues')
    records = item.get('patient_records')
    limit = cfg.get('max_encounters')
    if (type(limit) is not int or limit <= 0 or not isinstance(dialogues, list) or
            len(dialogues) != limit or not isinstance(records, list) or not records or
            not isinstance(records[-1], dict) or not isinstance(dialogues[-1], dict)):
        return 'INCOMPLETE'
    last = records[-1]
    department = last.get('Recording Department')
    next_step = last.get('next_step')
    ongoing = ((department == 'registration' and next_step == 'specialist_consultation') or
               (department == 'specialist_consultation' and next_step == 'diagnostic_test') or
               (department == 'diagnostic_test' and next_step is None))
    if ongoing and dialogues[-1].get('department') == department:
        return 'ENCOUNTER_LIMIT'
    return 'INCOMPLETE'

def rows(path):
    with open(path, encoding='utf-8-sig') as source:
        result = []
        for line in source:
            if line.strip():
                obj = json.loads(line)
                if not isinstance(obj, dict):
                    raise ValueError('JSONL record is not an object')
                result.append(obj)
        return result

def validate_inference(items, allow_failed=False):
    if not items:
        raise ValueError('No inference records')
    for item in items:
        original = item.get('original_data')
        if not isinstance(original, dict) or any(key not in original for key in (
                'id', 'Case Information', 'Physical Examination', 'Diagnostic Tests', 'Final Diagnosis')):
            raise ValueError('Inference record is missing case data')
        if not isinstance(item.get('process_success'), bool):
            raise ValueError('Inference record has invalid process status')
        if not allow_failed and item['process_success'] is not True:
            raise ValueError('Inference record is not successful')
        for key in ('patient_records', 'doctor_patient_diaglogues', 'tool_usages'):
            if not isinstance(item.get(key), list):
                raise ValueError('Inference record has invalid collections')

def validate_scores(items, strict=False):
    if not items:
        raise ValueError('No evaluation records')
    expected = {'WC', 'DR', 'DR@3', 'DR@5', 'IC', 'RU', 'TP', 'TCA',
                'mdt', 'pubmed', 'wikipedia', 'IS', 'CTC', 'MDTRA',
                'LC', 'PS', 'TME', 'TI', 'RC', 'ED', 'FP'}
    for item in items:
        scores = item.get('scores')
        if not isinstance(scores, dict) or not scores:
            raise ValueError('Missing evaluation scores')
        if strict and not expected.issubset(scores):
            raise ValueError('Missing expected evaluation score keys')
        for value in scores.values():
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                raise ValueError('Invalid score')

def verify_originals():
    paths = ['codes/inference.py', 'codes/evaluation.py', 'codes/pipeline.py',
             'codes/utils/agents.py', 'codes/utils/tools.py', 'codes/utils/mdt.py',
             'codes/utils/run_context.py', 'codes/utils/tool_manager.py', 'requirements.txt']
    for path in paths:
        for command in (['git', 'ls-files', '--error-unmatch', '--', path],
                        ['git', 'diff', '--quiet', 'HEAD', '--', path]):
            if subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
                raise RuntimeError('Tracked original files must match HEAD')

def patch_chat():
    from openai.resources.chat.completions import Completions
    from openai.resources.responses import Responses
    original = Completions.create
    def create(self, *args, **kwargs):
        if kwargs.get('model') == 'deepseek-flash':
            extra = dict(kwargs.get('extra_body') or {})
            extra['thinking'] = {'type': 'disabled'}
            kwargs['extra_body'] = extra
        try:
            result = original(self, *args, **kwargs)
            api_successes.append(True)
            return result
        except Exception as exc:
            api_errors.append(type(exc).__name__)
            raise
    Completions.create = create
    original_response = Responses.create
    def create_response(self, *args, **kwargs):
        try:
            result = original_response(self, *args, **kwargs)
            api_successes.append(True)
            return result
        except Exception as exc:
            api_errors.append(type(exc).__name__)
            raise
    Responses.create = create_response

def patch_inference_errors():
    from concurrent.futures import Future
    import pipeline
    from utils.tool_manager import ToolManager
    original_talk = pipeline.talk_with_doctor
    original_tool = ToolManager.call_tool
    original_result = Future.result
    def talk(*args, **kwargs):
        try:
            return original_talk(*args, **kwargs)
        except Exception as exc:
            record_failure('ENCOUNTER', exc)
            raise
    def tool(*args, **kwargs):
        try:
            return original_tool(*args, **kwargs)
        except Exception as exc:
            record_failure('TOOL', exc)
            raise
    def result(self, *args, **kwargs):
        try:
            return original_result(self, *args, **kwargs)
        except Exception as exc:
            record_failure('WORKER', exc)
            raise
    pipeline.talk_with_doctor = talk
    ToolManager.call_tool = tool
    Future.result = result

status = False
diagnostic = None
try:
    with contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
        if action == 'verify':
            verify_originals()
            status = True
        elif action == 'validate_input':
            stage = 'INPUT_VALIDATION'
            validate_inference(rows(cfg['input']), cfg.get('allow_failed', False))
            status = True
        elif action == 'check_output':
            stage = 'INPUT_VALIDATION'
            if os.path.exists(cfg['output']) and os.path.samefile(cfg['input'], cfg['output']):
                raise ValueError('Evaluation output is the inference input')
            status = True
        elif action == 'inference':
            stage = 'INFERENCE'
            patch_chat()
            patch_inference_errors()
            stage = 'DATASET'
            import datasets
            load = datasets.load_dataset
            first_ids = []
            def checked_load(*args, **kwargs):
                try:
                    data = load(*args, **kwargs)
                    if not len(data):
                        raise ValueError('Dataset is empty')
                    first_case = data[0]
                    first_id = first_case['id']
                    first_ids.append(first_id)
                    if os.path.exists(cfg['result']):
                        existing = rows(cfg['result'])
                        if existing:
                            validate_inference(existing)
                            if len(existing) != 1 or existing[0]['original_data'] != first_case:
                                raise ValueError('Resume data does not match the first selected case')
                            global resumed
                            resumed = True
                    return data
                except Exception as exc:
                    record_failure('DATASET', exc)
                    raise
            datasets.load_dataset = checked_load
            sys.argv = ['codes/inference.py', '--data_repo_path', cfg['data_repo'],
                        '--parallel_workers', str(cfg['parallel_workers']),
                        '--patient_model_name', cfg['patient_model'], '--patient_base_url', cfg['patient_url'],
                        '--patient_api_key', os.environ['CP_PATIENT_KEY'],
                        '--doctor_model_name', cfg['doctor_model'], '--doctor_base_url', cfg['doctor_url'],
                        '--doctor_api_key', os.environ['CP_DOCTOR_KEY'],
                        '--max_encounter_nums', str(cfg['max_encounters']),
                        '--max_talk_turns', str(cfg['max_turns']), '--max_query_nums', str(cfg['max_queries'])]
            if cfg['responses']:
                sys.argv.append('--doctor_responses_api')
            stage = 'INFERENCE'
            runpy.run_path('codes/inference.py', run_name='__main__')
            stage = 'RESULT_VALIDATION'
            items = rows(cfg['result'])
            diagnostic = inference_diagnostic(items)
            validate_inference(items)
            if len(first_ids) != 1 or len(items) != 1 or items[0]['original_data']['id'] != first_ids[0]:
                raise ValueError('Result does not match the selected case')
            text = captured_text()
            if 'Error processing data item:' in text or '--- ERROR DETECTED' in text:
                raise RuntimeError('Inference reported an error')
            status = True
        elif action == 'evaluation':
            stage = 'INPUT_VALIDATION'
            inputs = rows(cfg['input'])
            validate_inference(inputs, cfg.get('allow_failed', False))
            patch_chat()
            sys.argv = ['codes/evaluation.py', '--input_file', cfg['input'], '--output', cfg['output'],
                        '--model', cfg['model'], '--base_url', cfg['url'],
                        '--api_key', os.environ['CP_EVALUATOR_KEY'], '--max_workers', str(cfg['max_workers'])]
            stage = 'EVALUATION'
            runpy.run_path('codes/evaluation.py', run_name='__main__')
            stage = 'RESULT_VALIDATION'
            results = rows(cfg['output'])
            validate_scores(results, strict=True)
            expected = [item['original_data']['id'] for item in inputs]
            actual = [item.get('case_id') for item in results]
            if len(actual) != len(expected) or sorted(map(repr, actual)) != sorted(map(repr, expected)):
                raise ValueError('Evaluation did not produce one result per input case')
            text = captured_text()
            if not api_successes or 'Error:' in text or 'API call failed' in text:
                raise RuntimeError('Evaluation reported an error')
            status = True
        elif action == 'stats':
            stage = 'STATISTICS'
            results = rows(cfg['output'])
            validate_scores(results)
            sys.argv = ['codes/evaluation.py', '--output', cfg['output'], '--stats_only',
                        '--api_key', 'offline', '--base_url', 'https://example.invalid']
            runpy.run_path('codes/evaluation.py', run_name='__main__')
            if 'Error:' in captured_text():
                raise RuntimeError('Statistics failed')
            status = True
        else:
            raise ValueError('Unknown action')
except BaseException as exc:
    record_failure(stage, exc)

try:
    text = captured_text()
except Exception as exc:
    text = ''
    status = False
    record_failure('CAPTURE', exc)
found = sorted({name for name in categories if name in api_errors or any(event[1] == name for event in failure_events)})
if found:
    print('SAFE_CATEGORIES=' + ', '.join(found))
if not status:
    if diagnostic:
        print('SAFE_DIAGNOSTIC=' + diagnostic)
    for event_stage, name in sorted(set(failure_events)):
        print('SAFE_FAILURE=' + event_stage + ':' + name)
    for name in sorted(set(api_errors)):
        print('SAFE_FAILURE=API:' + (name if name in categories else 'OtherError'))
if status and action == 'inference' and resumed:
    print('SAFE_RESUMED=YES')
if status and action == 'evaluation' and api_errors:
    print('SAFE_EVALUATION_API_FAILURES=YES')
if status and action in ('stats', 'evaluation'):
    for line in text.splitlines():
        clean = line.strip()
        if clean in ('[Clinical Efficacy]', '[Process Competency]', '[Professional Ethics]') or re.fullmatch(r'(?:WC|DR@3|DR@5|TP|IS|LC|RC|IC|RU|PS|TI|ED|FP)\s*:\s*-?\d+(?:\.\d+)?', clean) or re.fullmatch(r'Total Cases Evaluated: \d+', clean):
            print('SAFE_STAT=' + clean)
print('SAFE_STATUS=' + ('OK' if status else 'FAILED'))
sys.exit(0 if status else 1)
'@

function Invoke-Runner([hashtable]$Config) {
    $env:CP_WORKFLOW_CONFIG = $Config | ConvertTo-Json -Compress -Depth 5
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @($runner | & $python - 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    $statuses = @()
    $stages = @{
        SETUP='workflow setup'; DATASET='dataset loading'; INFERENCE='inference execution';
        ENCOUNTER='inference encounter'; TOOL='tool execution'; WORKER='worker execution'; API='model API call';
        INPUT_VALIDATION='input validation'; RESULT_VALIDATION='result validation';
        EVALUATION='evaluation execution'; STATISTICS='statistics'; CAPTURE='output capture'
    }
    $errors = @{
        AuthenticationError='API authentication was rejected; check the selected endpoint and credentials.'
        BadRequestError='API request was rejected; check the model ID, endpoint, and API compatibility.'
        APIConnectionError='An API connection failed; check the endpoint and network.'
        APITimeoutError='An API request timed out.'
        RateLimitError='An API rate limit was reached.'
        InternalServerError='The API service reported a server error.'
        JSONDecodeError='JSON parsing failed.'; KeyError='A required field was missing.'
        IndexError='A required item was missing.'; TypeError='A value had an unexpected type.'
        AttributeError='An expected attribute was missing.'; ModuleNotFoundError='A required module was unavailable.'
        ImportError='A required import failed.'; SyntaxError='A syntax error occurred.'
        FileNotFoundError='A required file was unavailable.'; PermissionError='A filesystem permission was denied.'
        ValueError='A value or result failed validation.'; OSError='A filesystem or operating-system error occurred.'
        RuntimeError='A runtime check or operation failed.'; OtherError='An unclassified error occurred.'
    }
    foreach ($item in $output) {
        # Native stderr is captured as ErrorRecord objects; it is never protocol output.
        if ($item -isnot [string]) { continue }
        $line = [string]$item
        if ($line -ceq 'SAFE_STATUS=OK' -or $line -ceq 'SAFE_STATUS=FAILED') { $statuses += $line }
        elseif ($line -cmatch '^SAFE_CATEGORIES=([A-Za-z]+(?:, [A-Za-z]+)*)$') {
            $names = @($Matches[1] -split ', ')
            if (@($names | Where-Object { -not $errors.ContainsKey($_) }).Count -eq 0) {
                Write-Host ('Observed exception categories: ' + ($names -join ', '))
            }
        }
        elseif ($line -cmatch '^SAFE_FAILURE=([A-Z_]+):([A-Za-z]+)$') {
            $failureStage = $Matches[1]; $failureClass = $Matches[2]
            if ($stages.ContainsKey($failureStage) -and $errors.ContainsKey($failureClass)) {
                Write-Host ('Observed diagnostic (' + $stages[$failureStage] + ', ' + $failureClass + '): ' + $errors[$failureClass])
            }
        }
        elseif ($line -ceq 'SAFE_DIAGNOSTIC=ENCOUNTER_LIMIT') {
            Write-Host $line
            Write-Host 'The encounter limit appears to have been reached while the workflow was ongoing. On a fresh run, consider increasing Maximum encounters; choose backup and restart to retain the failed result.'
        }
        elseif ($line -ceq 'SAFE_DIAGNOSTIC=INCOMPLETE') { Write-Host $line; Write-Host 'The inference record is incomplete; the cause is not established.' }
        elseif ($line -ceq 'SAFE_RESUMED=YES') { Write-Host 'Existing first-case result was reused; current inference settings may not have been applied.' }
        elseif ($line -ceq 'SAFE_EVALUATION_API_FAILURES=YES') { Write-Host 'Warning: some evaluation API calls failed; fallback scores may have been used.' }
        elseif ($line -match '^SAFE_STAT=(\[(Clinical Efficacy|Process Competency|Professional Ethics)\]|(WC|DR@3|DR@5|TP|IS|LC|RC|IC|RU|PS|TI|ED|FP)\s*:\s*-?\d+(\.\d+)?|Total Cases Evaluated: \d+)$') { Write-Host $Matches[1] }
    }
    if ($code -ne 0 -or $statuses.Count -ne 1 -or $statuses[0] -cne 'SAFE_STATUS=OK') {
        Write-Host "Python process exit code: $code; verified workflow status: failed."
        return $false
    }
    return $true
}

try {
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Python virtual environment not found at .venv\Scripts\python.exe; create the venv and install requirements first.' }
    Push-Location -LiteralPath $PSScriptRoot
    try {
        Write-Host '1 Inference + evaluation | 2 Inference only | 3 Evaluate existing inference | 4 Statistics only | 0 Quit'
        $mode = Read-Choice 'Choose mode' '1' @('0', '1', '2', '3', '4')
        if ($mode -eq '0') { return }
        if ($mode -ne '4' -and -not (Invoke-Runner @{ action = 'verify' })) { throw 'Cannot verify original tracked files against HEAD (or Git is unavailable); no workflow started.' }
        if ($mode -in @('1', '2')) {
            Write-Host 'Profiles: 1=Quick DeepSeek test (DeepSeek patient and doctor); 2=Paper-style patient setup (GPT-OSS patient, evaluated doctor).'
            $profile = Read-Choice 'Choose model profile' '1' @('1', '2')
            if ($profile -eq '1') {
                $patientModelDefault = 'deepseek-flash'
                $patientUrlDefault = 'https://api.deepseek.com'
                $doctorModelDefault = 'deepseek-flash'
                $doctorUrlDefault = 'https://api.deepseek.com'
                $evaluatorModelDefault = 'deepseek-flash'
                $evaluatorUrlDefault = 'https://api.deepseek.com'
            }
            else {
                $patientModelDefault = 'gpt-oss-120b'
                $patientUrlDefault = 'http://localhost:8000/v1'
                $doctorModelDefault = 'deepseek-flash'
                $doctorUrlDefault = 'https://api.deepseek.com'
                $evaluatorModelDefault = 'gpt-oss-120b'
                $evaluatorUrlDefault = $patientUrlDefault
                Write-Host 'Paper-style: the paper fixes GPT-OSS-120B as the patient model; it must already be served at the selected patient endpoint.'
                Write-Host 'The evaluator default below follows this repository CLI; the paper does not clearly specify its evaluator model.'
            }
            Write-Host 'Operational defaults: one inference worker to reduce API contention; original pathway limits are 8 encounters, 5 talk turns, 3 queries.'
            Write-Host 'The original inference code selects only the first test-split case; model names determine its output filename.'
        }
        $inputPath = $null
        if ($mode -in @('1', '2')) {
            $patientModel = Read-Model 'Patient model' $patientModelDefault
            $patientUrl = Read-BaseUrl 'Patient base URL' $patientUrlDefault
            $patientKeyPrompt = if ($profile -eq '2') { 'Enter patient API key (hidden; local vLLM can use EMPTY)' } else { 'Enter patient API key (hidden)' }
            $env:CP_PATIENT_KEY = Read-Key $patientKeyPrompt
            $doctorModel = Read-Model 'Doctor model' $doctorModelDefault
            $doctorUrl = Read-BaseUrl 'Doctor base URL' $doctorUrlDefault
            $keyDefault = if ($doctorUrl.TrimEnd('/') -ieq $patientUrl.TrimEnd('/')) { '2' } else { '1' }
            $env:CP_DOCTOR_KEY = Read-SelectedKey 'Doctor' $keyDefault $true $false
            $responses = (Read-Choice 'Doctor Responses API? y/n' 'n' @('y', 'n')) -eq 'y'
            $workers = Read-Positive 'Inference parallel workers' 1
            $dataRepo = Read-Default 'Dataset repository or path' 'SII-SPIRAL-MED/DiagnosisArena'
            $encounters = Read-Positive 'Maximum encounters' 8
            $turns = Read-Positive 'Maximum talk turns' 5
            $queries = Read-Positive 'Maximum queries' 3
            $inputPath = Join-Path $PSScriptRoot "outputs\P_$patientModel-D_$doctorModel-results.jsonl"
            $logPath = Join-Path $PSScriptRoot "logs\mimic_process_$doctorModel.log"
            Write-Host "Inference output: $inputPath"
            if (Test-Path -LiteralPath $inputPath) {
                if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) { throw 'Inference output path is not a file.' }
                if ((Get-Item -LiteralPath $inputPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Inference output path is a link; refusing to write through it.' }
                $choice = Read-Choice 'Existing inference: 1=resume, 2=backup and restart, 0=cancel' '0' @('0', '1', '2')
                if ($choice -eq '0') { throw 'Cancelled; existing artifacts were not changed.' }
                if ($choice -eq '1') {
                    Write-Host 'Warning: the existing first-case result may be reused, not newly inferred. Endpoints, limits and Responses API settings cannot be verified and may not be applied.'
                    if ((Read-Choice 'Acknowledge reuse and continue? y/n' 'n' @('y', 'n')) -ne 'y') { throw 'Cancelled; existing artifacts were not changed.' }
                }
                Backup-Artifact $inputPath ($choice -eq '2')
            }
            if (Test-Path -LiteralPath $logPath) {
                if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { throw 'Log path is not a file.' }
                if ((Get-Item -LiteralPath $logPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Log path is a link; refusing to write through it.' }
                Backup-Artifact $logPath $true
            }
            Write-Host 'Original logs may contain sensitive patient data; keep logs and backups private.'
            Write-Host 'Starting the original inference/resume workflow; raw Python output is suppressed for safety.'
            $config = @{ action='inference'; result=$inputPath; data_repo=$dataRepo; parallel_workers=$workers;
                patient_model=$patientModel; patient_url=$patientUrl; doctor_model=$doctorModel; doctor_url=$doctorUrl;
                responses=$responses; max_encounters=$encounters; max_turns=$turns; max_queries=$queries }
            if (-not (Invoke-Runner $config)) { throw 'Inference did not complete successfully. Artifacts were retained; evaluation was skipped. For a failed resume, choose backup and restart.' }
            Write-Host 'First-case result verified successful (a matching existing result may have been reused).'
            if ($mode -eq '2') { return }
        }
        if ($mode -eq '3') {
            $inputPath = Resolve-WorkspacePath (Read-Default 'Existing inference JSONL path' '.\outputs\P_deepseek-flash-D_deepseek-flash-results.jsonl')
            if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) { throw 'Inference input file not found.' }
        }
        if ($mode -eq '4') {
            $outputPath = Resolve-WorkspacePath (Read-Default 'Existing evaluation JSONL path' '.\outputs\deepseek-fixed-smoke-evaluation.jsonl')
            if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw 'Evaluation file not found.' }
            Write-Host 'Statistics only: no API key or network request is required.'
            if (-not (Invoke-Runner @{ action='stats'; output=$outputPath })) { throw 'Statistics could not be calculated from this file.' }
            return
        }
        $allowFailed = $false
        if ($mode -eq '3') {
            Write-Host 'Warning: evaluating failed inference records can make the original metrics misleading.'
            $allowFailed = (Read-Choice 'Allow evaluation of failed records? y/n' 'n' @('y', 'n')) -eq 'y'
        }
        if (-not (Invoke-Runner @{ action='validate_input'; input=$inputPath; allow_failed=$allowFailed })) { throw 'Inference input is invalid, empty, or contains failed cases; evaluation was skipped.' }
        $defaultOutput = Join-Path $PSScriptRoot ('outputs\evaluation-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.jsonl')
        $outputPath = Resolve-EvaluationOutput (Read-Default 'Evaluation output JSONL path' $defaultOutput)
        if ($outputPath -ieq $inputPath) { throw 'Evaluation output must differ from inference input.' }
        if (-not (Invoke-Runner @{ action='check_output'; input=$inputPath; output=$outputPath })) { throw 'Evaluation output must differ from inference input, including links.' }
        $modelDefault = if ($mode -eq '1') { $evaluatorModelDefault } else { 'deepseek-flash' }
        $urlDefault = if ($mode -eq '1') { $evaluatorUrlDefault } else { 'https://api.deepseek.com' }
        $evalModel = Read-EvaluatorModel 'Evaluator model (ID, not output path)' $modelDefault
        $evalUrl = Read-BaseUrl 'Evaluator base URL' $urlDefault
        if ($mode -eq '1') {
            $keyDefault = if ($evalUrl.TrimEnd('/') -ieq $doctorUrl.TrimEnd('/')) { '3' } elseif ($evalUrl.TrimEnd('/') -ieq $patientUrl.TrimEnd('/')) { '2' } else { '1' }
            $env:CP_EVALUATOR_KEY = Read-SelectedKey 'Evaluator' $keyDefault $true $true
        } else { $env:CP_EVALUATOR_KEY = Read-Key 'Enter evaluator API key (hidden)' }
        $evalWorkers = Read-Positive 'Evaluation max workers' 4
        $outputPath = Resolve-EvaluationOutput $outputPath
        if (-not (Invoke-Runner @{ action='check_output'; input=$inputPath; output=$outputPath })) { throw 'Evaluation output must differ from inference input, including links.' }
        if (Test-Path -LiteralPath $outputPath) {
            if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw 'Evaluation output path is not a file.' }
            $choice = Read-Choice 'Existing evaluation output: 1=backup and replace, 0=cancel' '0' @('0', '1')
            if ($choice -eq '0') { throw 'Cancelled; existing evaluation output was not changed.' }
            Backup-Artifact $outputPath $true
        }
        Write-Host 'Running evaluation; raw Python output is suppressed for safety.'
        $outputPath = Resolve-EvaluationOutput $outputPath
        if (Test-Path -LiteralPath $outputPath) { throw 'Evaluation output unexpectedly exists; refusing to overwrite it.' }
        if (-not (Invoke-Runner @{ action='evaluation'; input=$inputPath; output=$outputPath; model=$evalModel; url=$evalUrl; max_workers=$evalWorkers; allow_failed=$allowFailed })) {
            throw 'Evaluation did not complete successfully; all artifacts were retained.'
        }
        Write-Host 'Evaluation output structure verified and at least one API call completed. The original evaluator silently substitutes fallback scores for API, input or parsing errors; metrics are not guaranteed valid.'
    }
    finally { Pop-Location }
}
catch {
    $safeMessages = @('Python virtual environment not found', 'Cannot verify original tracked files', 'Input cancelled',
        'No API key entered', 'Inference output path is not a file', 'Inference output path is a link', 'Log path is not a file', 'Log path is a link', 'Cancelled;',
        'Inference did not complete successfully', 'Inference input file not found', 'Inference input is invalid', 'Evaluation file not found',
        'Statistics could not be calculated', 'Evaluation output must differ', 'Evaluation output cannot', 'Evaluation output must be', 'Evaluation output parent directory', 'Evaluation output unexpectedly exists',
        'Evaluation output path is not a file', 'Evaluation did not complete successfully', 'A file path is required')
    $message = $_.Exception.Message
    $safe = $false
    foreach ($prefix in $safeMessages) { if ($message.StartsWith($prefix, [StringComparison]::Ordinal)) { $safe = $true; break } }
    if ($safe) { Write-Host ('FAILED: ' + $message) } else { Write-Host 'FAILED: Operation stopped due to an input, filesystem, or runtime error; existing artifacts were retained where possible.' }
    $global:LASTEXITCODE = 1
}
finally {
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
    $ErrorActionPreference = $savedErrorActionPreference
}
