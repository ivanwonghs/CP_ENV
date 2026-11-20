@echo off
setlocal DisableDelayedExpansion
set "errorlevel="
set "CP_WORKFLOW_LAUNCHER=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$code = 1; $temp = $null; try { $policies = @(Get-ExecutionPolicy -List); if (@($policies | Where-Object { $_.Scope -in @('MachinePolicy','UserPolicy') -and $_.ExecutionPolicy -ne 'Undefined' }).Count -gt 0) { Write-Warning 'A managed execution policy may override this process-level bypass.' }; $content = [IO.File]::ReadAllText($env:CP_WORKFLOW_LAUNCHER, [Text.Encoding]::UTF8).Replace(([string][char]13 + [char]10), ([string][char]10)); $marker = (([string][char]10) + ':__POWERSHELL__' + [char]10); $position = $content.IndexOf($marker, [StringComparison]::Ordinal); if ($position -lt 0) { throw 'Readable PowerShell section not found.' }; $script = $content.Substring($position + $marker.Length); $tempPath = [IO.Path]::Combine([IO.Path]::GetDirectoryName($env:CP_WORKFLOW_LAUNCHER), ('.full_workflow_executor-' + [guid]::NewGuid().ToString('N') + '.ps1')); $file = [IO.File]::Open($tempPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); $temp = $tempPath; try { $encoding = New-Object Text.UTF8Encoding($true); $bom = $encoding.GetPreamble(); $file.Write($bom, 0, $bom.Length); $bytes = $encoding.GetBytes($script); $file.Write($bytes, 0, $bytes.Length) } finally { $file.Dispose() }; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $temp; $code = $LASTEXITCODE } catch { [Console]::Error.WriteLine('Launcher failed: ' + $_.Exception.Message); $code = 1 } finally { if ($null -ne $temp) { try { Remove-Item -LiteralPath $temp -Force -ErrorAction Stop } catch { Write-Warning ('Could not remove temporary script: ' + $temp) } } }; exit $code"
set "CP_WORKFLOW_EXIT_CODE=%errorlevel%"
echo.
set /p "CP_WORKFLOW_CLOSE=Press Enter to close..."
exit /b %CP_WORKFLOW_EXIT_CODE%
:__POWERSHELL__
# Run from any directory; Enter selects the displayed default; Ctrl+C cancels.
# Python output is filtered because it can contain keys or patient data.
if ($env:OS -eq 'Windows_NT') {
    Write-Host 'Windows launch: .\full_workflow_executor.cmd'
}
else {
    Write-Host 'macOS launch: install PowerShell 7, then run: pwsh ./full_workflow_executor.ps1'
}
Write-Host 'Prerequisites: system Python 3.12 or 3.13 and PowerShell. First run installs dependencies into .python-packages; no virtual environment or global Python install is used.'
$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Stop'

# Keep credentials and launcher-installed dependencies out of Git after a fresh clone.
$gitignorePath = Join-Path $PSScriptRoot '.gitignore'
$requiredIgnoreRules = @('.env', '.env.*', '.venv/', 'venv/', '.python-packages/', '__pycache__/', '*.py[cod]')
if (Test-Path -LiteralPath $gitignorePath) {
    $gitignoreItem = Get-Item -LiteralPath $gitignorePath -Force
    if (-not $gitignoreItem.PSIsContainer -and ($gitignoreItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw '.gitignore is a link; refusing to write through it.'
    }
    if ($gitignoreItem.PSIsContainer) { throw '.gitignore exists as a directory; refusing to replace it.' }
    $existingIgnoreRules = @(Get-Content -LiteralPath $gitignorePath)
    $missingIgnoreRules = @($requiredIgnoreRules | Where-Object { $existingIgnoreRules -notcontains $_ })
    if ($missingIgnoreRules.Count -gt 0) {
        Add-Content -LiteralPath $gitignorePath -Value ("`n# Local secrets and launcher dependencies" + [Environment]::NewLine + ($missingIgnoreRules -join [Environment]::NewLine))
        Write-Host 'Added missing local-secret and launcher-dependency rules to .gitignore.'
    }
}
else {
    Set-Content -LiteralPath $gitignorePath -Value ($requiredIgnoreRules -join [Environment]::NewLine) -Encoding UTF8
    Write-Host 'Created a default .gitignore for .env, virtualenvs, and local launcher dependencies.'
}

$pythonCommand = $null
$pythonPrefix = @()
$pythonVersion = $null
$candidates = @()
if (Get-Command py -ErrorAction SilentlyContinue) {
    $candidates += [pscustomobject]@{ Command = 'py'; Prefix = @('-3.12') }
    $candidates += [pscustomobject]@{ Command = 'py'; Prefix = @('-3.13') }
}
foreach ($name in @('python3.12', 'python3.13', 'python3', 'python')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { $candidates += [pscustomobject]@{ Command = $command.Source; Prefix = @() } }
}
foreach ($candidate in $candidates) {
    $versionArgs = @($candidate.Prefix) + @('-c', 'import sys; print(sys.version_info[0], sys.version_info[1])')
    $version = & $candidate.Command @versionArgs 2>$null
    if ($LASTEXITCODE -eq 0 -and [string]$version -match '^3\s+(12|13)$') {
        $pythonCommand = $candidate.Command
        $pythonPrefix = @($candidate.Prefix)
        $pythonVersion = ([string]$version -replace '\s+', '.')
        break
    }
}
if (-not $pythonCommand) {
    throw 'Python 3.12 or 3.13 is required. Install one system-wide, then rerun; this script does not create a virtual environment.'
}

$requirements = Join-Path $PSScriptRoot 'requirements.txt'
$packagePath = Join-Path $PSScriptRoot '.python-packages'
$packageMarker = Join-Path $packagePath '.requirements-sha256'
$requirementsHash = (Get-FileHash -LiteralPath $requirements -Algorithm SHA256).Hash
$optionalPackages = @('langchain-community==0.3.31', 'wikipedia==1.4.0', 'xmltodict==0.14.2')
$expectedMarker = "$pythonVersion`:$requirementsHash`:$($optionalPackages -join ';')"
if (-not (Test-Path -LiteralPath $packageMarker) -or
    (Get-Content -LiteralPath $packageMarker -Raw).Trim() -ne $expectedMarker) {
    Write-Host "Installing pinned Python dependencies into repo-local .python-packages with system Python $pythonVersion (no virtual environment or global package install)."
    New-Item -ItemType Directory -Force -Path $packagePath | Out-Null
    $installArgs = @($pythonPrefix) + @('-m', 'pip', 'install', '--disable-pip-version-check', '--quiet', '--upgrade', '--target', $packagePath, '-r', $requirements) + $optionalPackages
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $installOutput = @(& $pythonCommand @installArgs 2>&1)
        $installExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($installExitCode -ne 0) {
        throw 'Dependency installation failed. Check internet access and that Python 3.12/3.13 includes pip; no virtual environment was created.'
    }
    Set-Content -LiteralPath $packageMarker -Value $expectedMarker -Encoding ASCII
}
$python = $pythonCommand
$envNames = @('CP_WORKFLOW_CONFIG', 'CP_PATIENT_KEY', 'CP_DOCTOR_KEY', 'CP_EVALUATOR_KEY', 'CP_LOCAL_PACKAGES')
$savedEnvironment = @{}
foreach ($name in $envNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$env:CP_LOCAL_PACKAGES = $packagePath

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
function Read-DotEnv {
    $path = Join-Path $PSScriptRoot '.env'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw '.env was selected but no .env file exists in the repository folder.'
    }
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $path) {
        $text = ([string]$line).Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        $text = $text -replace '^export\s+', ''
        if ($text -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { continue }
        $name = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$name] = $value
    }
    return $values
}
function Resolve-DotEnvKey([hashtable]$Values, [string]$Role, [string]$Model, [string]$BaseUrl) {
    $roleName = $Role.ToUpperInvariant()
    foreach ($name in @("${roleName}_API_KEY", "CP_${roleName}_KEY")) {
        if ($Values.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace([string]$Values[$name])) {
            return [string]$Values[$name]
        }
    }
    $uri = $null
    $isDeepSeek = ($Model -eq 'deepseek-flash') -or
        ([Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -and $uri.Host -eq 'api.deepseek.com')
    if ($isDeepSeek -and $Values.ContainsKey('DEEPSEEK_API_KEY') -and
        -not [string]::IsNullOrWhiteSpace([string]$Values['DEEPSEEK_API_KEY'])) {
        return [string]$Values['DEEPSEEK_API_KEY']
    }
    if ([Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -and $uri.IsLoopback) {
        return 'EMPTY'
    }
    throw "No .env key configured for $Role at the selected provider. Set ${roleName}_API_KEY; for DeepSeek you may use DEEPSEEK_API_KEY."
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
import ast
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
local_packages = os.environ.get('CP_LOCAL_PACKAGES')
if local_packages:
    sys.path.insert(0, local_packages)
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
    from utils.run_context import RunContext
    import threading
    write_lock = threading.Lock()
    original_write = RunContext.output_agent_results
    def locked_write(self):
        with write_lock:
            return original_write(self)
    RunContext.output_agent_results = locked_write
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

def run_inference_with_paths(result_path, log_path):
    """Set run-specific paths in memory, without modifying inference.py."""
    path = 'codes/inference.py'
    with open(path, encoding='utf-8-sig') as source:
        tree = ast.parse(source.read(), filename=path)
    args_classes = [node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == 'Args']
    if len(args_classes) != 1:
        raise RuntimeError('Inference Args class could not be located')
    initializers = [node for node in args_classes[0].body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == '__init__']
    if len(initializers) != 1:
        raise RuntimeError('Inference Args initializer could not be located')
    assignments = [node for node in initializers[0].body if isinstance(node, ast.Assign) and any(
        isinstance(target, ast.Attribute) and isinstance(target.value, ast.Name) and target.value.id == 'self' and target.attr == 'output_path'
        for target in node.targets)]
    log_calls = [node for node in tree.body if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
        and isinstance(node.value.func, ast.Attribute) and isinstance(node.value.func.value, ast.Name)
        and node.value.func.value.id == 'logging' and node.value.func.attr == 'basicConfig']
    if len(assignments) != 1 or len(log_calls) != 1:
        raise RuntimeError('Inference output or logging configuration could not be located')
    filenames = [keyword for keyword in log_calls[0].value.keywords if keyword.arg == 'filename']
    if len(filenames) != 1:
        raise RuntimeError('Inference log filename could not be located')
    if os.path.exists(result_path) or os.path.exists(log_path):
        raise RuntimeError('Run-specific output or log already exists')
    assignments[0].value = ast.copy_location(ast.Constant(value=result_path), assignments[0].value)
    filenames[0].value = ast.copy_location(ast.Constant(value=log_path), filenames[0].value)
    ast.fix_missing_locations(tree)
    namespace = {'__name__': '__main__', '__file__': os.path.abspath(path), '__package__': None}
    exec(compile(tree, path, 'exec'), namespace)

status = False
diagnostic = None
try:
    with contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
        if action == 'verify':
            if not all(os.path.isfile(path) for path in ('codes/inference.py', 'codes/evaluation.py', 'codes/pipeline.py', 'codes/utils/agents.py', 'codes/utils/tools.py', 'codes/utils/mdt.py', 'codes/utils/run_context.py', 'codes/utils/tool_manager.py', 'requirements.txt')):
                raise RuntimeError('Required workflow files are missing')
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
            expected_cases = {}
            def case_key(case):
                return json.dumps(case['id'], sort_keys=True, ensure_ascii=False)
            class SelectedDataset:
                def __init__(self, dataset):
                    self.dataset = dataset
                def __len__(self):
                    return len(self.dataset)
                def __getitem__(self, key):
                    return self.dataset[key]
                def __iter__(self):
                    return iter(self.dataset)
                def select(self, ignored_indices, *args, **kwargs):
                    global resumed, diagnostic
                    try:
                        count = cfg['case_count']
                        if type(count) is not int or count < 1:
                            raise ValueError('Invalid case count')
                        if count > len(self.dataset):
                            diagnostic = 'CASE_COUNT_EXCEEDS_DATASET'
                            raise ValueError('Case count exceeds dataset size')
                        selected = self.dataset.select(range(count), *args, **kwargs)
                        if expected_cases:
                            raise ValueError('Dataset was selected more than once')
                        for case in selected:
                            key = case_key(case)
                            if key in expected_cases:
                                raise ValueError('Duplicate case IDs in selected dataset')
                            expected_cases[key] = case
                        if os.path.exists(cfg['result']):
                            existing = rows(cfg['result'])
                            if existing:
                                validate_inference(existing)
                                seen = set()
                                for item in existing:
                                    case = item['original_data']
                                    key = case_key(case)
                                    if key in seen or key not in expected_cases or expected_cases[key] != case:
                                        raise ValueError('Existing results do not match selected cases')
                                    seen.add(key)
                                resumed = True
                        return selected
                    except Exception as exc:
                        record_failure('DATASET', exc)
                        raise
            def checked_load(*args, **kwargs):
                try:
                    data = load(*args, **kwargs)
                    if not len(data):
                        raise ValueError('Dataset is empty')
                    return SelectedDataset(data)
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
            run_inference_with_paths(cfg['result'], cfg['log_path'])
            stage = 'RESULT_VALIDATION'
            items = rows(cfg['result'])
            diagnostic = inference_diagnostic(items)
            validate_inference(items)
            actual_cases = {}
            for item in items:
                case = item['original_data']
                key = case_key(case)
                if key in actual_cases:
                    raise ValueError('Duplicate result IDs')
                actual_cases[key] = case
            if not expected_cases or actual_cases != expected_cases:
                raise ValueError('Results do not match all selected cases')
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
        $output = @($runner | & $pythonCommand @pythonPrefix - 2>&1)
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
        elseif ($line -ceq 'SAFE_DIAGNOSTIC=CASE_COUNT_EXCEEDS_DATASET') { Write-Host 'The requested case count exceeds the dataset size; no cases were run.' }
        elseif ($line -ceq 'SAFE_DIAGNOSTIC=INCOMPLETE') { Write-Host $line; Write-Host 'The inference record is incomplete; the cause is not established.' }
        elseif ($line -ceq 'SAFE_RESUMED=YES') { Write-Host 'Existing matching results were reused; current inference settings may not have been applied to those cases.' }
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
    Write-Host "Using system Python $pythonVersion; dependencies are isolated under .python-packages (no virtual environment)."
    Push-Location -LiteralPath $PSScriptRoot
    try {
        Write-Host '1 Inference + evaluation | 2 Inference only | 3 Evaluate existing inference | 4 Statistics only | 0 Quit'
        $mode = Read-Choice 'Choose mode' '1' @('0', '1', '2', '3', '4')
        if ($mode -eq '0') { return }
        if ($mode -ne '4' -and -not (Invoke-Runner @{ action = 'verify' })) { throw 'A required workflow file is missing; no workflow started.' }
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
            Write-Host 'Choose the case count and parallel workers separately; higher concurrency can increase API cost and rate limits.'
            Write-Host 'The launcher selects the first requested cases regardless of the hardcoded range in inference.py.'
        }
        $credentialMode = $null
        $dotEnvValues = @{}
        if ($mode -in @('1', '2', '3')) {
            $credentialMode = Read-Choice 'Credentials: 1=load from .env, 2=enter hidden prompts' '2' @('1', '2')
            if ($credentialMode -eq '1') {
                $dotEnvValues = Read-DotEnv
                Write-Host '.env loaded without displaying values. Use PATIENT_API_KEY, DOCTOR_API_KEY, EVALUATOR_API_KEY, or DEEPSEEK_API_KEY for DeepSeek.'
            }
            else { Write-Host 'API keys are requested with hidden input and are not written to .env.' }
        }
        $inputPath = $null
        if ($mode -in @('1', '2')) {
            $patientModel = Read-Model 'Patient model' $patientModelDefault
            $patientUrl = Read-BaseUrl 'Patient base URL' $patientUrlDefault
            if ($credentialMode -eq '1') {
                $env:CP_PATIENT_KEY = Resolve-DotEnvKey $dotEnvValues 'patient' $patientModel $patientUrl
            }
            else {
                $patientKeyPrompt = if ($profile -eq '2') { 'Enter patient API key (hidden; local vLLM can use EMPTY)' } else { 'Enter patient API key (hidden)' }
                $env:CP_PATIENT_KEY = Read-Key $patientKeyPrompt
            }
            $doctorModel = Read-Model 'Doctor model' $doctorModelDefault
            $doctorUrl = Read-BaseUrl 'Doctor base URL' $doctorUrlDefault
            if ($credentialMode -eq '1') {
                $env:CP_DOCTOR_KEY = Resolve-DotEnvKey $dotEnvValues 'doctor' $doctorModel $doctorUrl
            }
            else {
                $env:CP_DOCTOR_KEY = Read-SelectedKey 'Doctor' '2' $true $false
            }
            $responses = (Read-Choice 'Doctor Responses API? y/n' 'n' @('y', 'n')) -eq 'y'
            $caseCount = Read-Positive 'Number of cases' 1
            $workers = Read-Positive 'Inference parallel workers' 4
            $dataRepo = Read-Default 'Dataset repository or path' 'SII-SPIRAL-MED/DiagnosisArena'
            $encounters = Read-Positive 'Maximum encounters' 8
            $turns = Read-Positive 'Maximum talk turns' 5
            $queries = Read-Positive 'Maximum queries' 3
            $runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
            $inputPath = Join-Path $PSScriptRoot "outputs\P_$patientModel-D_$doctorModel-$runId-results.jsonl"
            $logPath = Join-Path $PSScriptRoot "logs\mimic_process_$doctorModel-$runId.log"
            Write-Host "Inference output: $inputPath"
            Write-Host "Inference log: $logPath"
            if ((Test-Path -LiteralPath $inputPath) -or (Test-Path -LiteralPath $logPath)) { throw 'Run-specific output or log already exists; no workflow started.' }
            Write-Host 'Original logs may contain sensitive patient data; keep logs and backups private.'
            Write-Host 'Starting inference in new run-specific files; raw Python output is suppressed for safety.'
            $config = @{ action='inference'; result=$inputPath; log_path=$logPath; data_repo=$dataRepo; parallel_workers=$workers; case_count=$caseCount;
                patient_model=$patientModel; patient_url=$patientUrl; doctor_model=$doctorModel; doctor_url=$doctorUrl;
                responses=$responses; max_encounters=$encounters; max_turns=$turns; max_queries=$queries }
            if (-not (Invoke-Runner $config)) { throw 'Inference did not complete successfully. Artifacts were retained; evaluation was skipped.' }
            Write-Host 'All selected case results verified successful.'
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
        $evaluationId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $defaultOutput = Join-Path $PSScriptRoot ('outputs\evaluation-' + $evaluationId + '.jsonl')
        $outputPath = Resolve-EvaluationOutput (Read-Default 'Evaluation output JSONL path' $defaultOutput)
        if ($outputPath -ieq $inputPath) { throw 'Evaluation output must differ from inference input.' }
        if (-not (Invoke-Runner @{ action='check_output'; input=$inputPath; output=$outputPath })) { throw 'Evaluation output must differ from inference input, including links.' }
        $modelDefault = if ($mode -eq '1') { $evaluatorModelDefault } else { 'deepseek-flash' }
        $urlDefault = if ($mode -eq '1') { $evaluatorUrlDefault } else { 'https://api.deepseek.com' }
        $evalModel = Read-EvaluatorModel 'Evaluator model (ID, not output path)' $modelDefault
        $evalUrl = Read-BaseUrl 'Evaluator base URL' $urlDefault
        if ($credentialMode -eq '1') {
            $env:CP_EVALUATOR_KEY = Resolve-DotEnvKey $dotEnvValues 'evaluator' $evalModel $evalUrl
        }
        elseif ($mode -eq '1') {
            $env:CP_EVALUATOR_KEY = Read-SelectedKey 'Evaluator' '2' $true $true
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
    $safeMessages = @('Python virtual environment not found', 'A required workflow file is missing', 'Input cancelled',
        'No API key entered', 'Run-specific output or log already exists', 'Cancelled;',
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
