param(
    [string]$BaselineExe,
    [string]$AcceptedExe,
    [Parameter(Mandatory=$true)][string]$SegmentDirectory,
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
    [string]$InputManifest,
    [switch]$PreflightOnly
)

# Run with Windows PowerShell -NoProfile -STA. This drives the installed GUI;
# it neither changes VC3D nor invokes its direct segment-attachment RPC.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Villa1849Native {
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
        public ushort wVk, wScan; public uint dwFlags, time; public UIntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
        public int dx, dy; public uint mouseData, dwFlags, time; public UIntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public MOUSEINPUT mi;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT {
        public uint type; public INPUTUNION data;
    }
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", SetLastError=true)] private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    public static uint ForegroundProcessId() {
        uint id; GetWindowThreadProcessId(GetForegroundWindow(), out id); return id;
    }
    private static void Send(INPUT[] inputs) {
        if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) != inputs.Length)
            throw new InvalidOperationException("Native input was not accepted by the interactive desktop.");
    }
    private static INPUT Key(ushort key, bool up) {
        INPUT input = new INPUT(); input.type = 1; input.data.ki.wVk = key;
        input.data.ki.dwFlags = up ? 2u : 0u; return input;
    }
    public static void SelectAll() { Send(new INPUT[] {Key(0x11,false),Key(0x41,false),Key(0x41,true),Key(0x11,true)}); }
    public static void Text(string text) {
        foreach (char c in text) {
            INPUT down = new INPUT(); down.type = 1; down.data.ki.wScan = c; down.data.ki.dwFlags = 4;
            INPUT up = down; up.data.ki.dwFlags = 6; Send(new INPUT[] {down,up});
        }
    }
    public static void Click(int x, int y) {
        if (!SetCursorPos(x,y)) throw new InvalidOperationException("Could not position native pointer.");
        INPUT down = new INPUT(); down.type = 0; down.data.mi.dwFlags = 2;
        INPUT up = down; up.data.mi.dwFlags = 4; Send(new INPUT[] {down,up});
    }
}
'@
[void][Villa1849Native]::SetProcessDPIAware()
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
$script:OwnedProcess = $null
$script:Events = New-Object 'System.Collections.Generic.List[object]'

function Write-Json($Value, [string]$Path) {
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Record([string]$Action, $Details) {
    $script:Events.Add([ordered]@{utc=[DateTime]::UtcNow.ToString('o');action=$Action;details=$Details})
    Write-Json $script:Events.ToArray() (Join-Path $EvidenceDirectory 'ui-events.json')
}
function Wait-For([scriptblock]$Probe, [string]$Description, [int]$Seconds=25) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $result = $null
        try { $result = & $Probe }
        catch [Windows.Automation.ElementNotAvailableException] { }
        if ($result) { return $result }
        if ($script:OwnedProcess) {
            $script:OwnedProcess.Refresh()
            if ($script:OwnedProcess.HasExited) { throw "VC3D exited while waiting for $Description" }
        }
        Start-Sleep -Milliseconds 200
    } while ($watch.Elapsed.TotalSeconds -lt $Seconds)
    throw "Timed out after ${Seconds}s waiting for $Description"
}
function Get-OwnedElements([int]$AppProcessId, $Root=$null) {
    if (!$Root) { $Root = [Windows.Automation.AutomationElement]::RootElement }
    $condition = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty, $AppProcessId)
    return $Root.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)
}
function Clean-Name([string]$Name) { return ($Name.Replace('&','') -replace '\.{3}$|\u2026$','').Trim() }
function Find-Control([int]$AppProcessId, [string]$Name, [string]$Type='', $Root=$null) {
    foreach ($element in (Get-OwnedElements $AppProcessId $Root)) {
        try {
            $current = $element.Current
            if ($current.IsOffscreen) { continue }
            if ($Type -and $current.ControlType.ProgrammaticName -ne "ControlType.$Type") { continue }
            if ((Clean-Name $current.Name) -eq $Name) { return $element }
        } catch [Windows.Automation.ElementNotAvailableException] { }
    }
    return $null
}
function Get-EditValue($Element) {
    $pattern = $null
    if (!$Element.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
        throw 'The actual edit has no readable UI Automation ValuePattern.'
    }
    return ([Windows.Automation.ValuePattern]$pattern).Current.Value
}
function Focus-Window($Window, [int]$AppProcessId) {
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    if ($handle -eq [IntPtr]::Zero) { throw 'The target top-level window has no native handle.' }
    [void][Villa1849Native]::ShowWindow($handle, 9)
    [void][Villa1849Native]::SetForegroundWindow($handle)
    [void](Wait-For { [Villa1849Native]::ForegroundProcessId() -eq $AppProcessId } 'VC3D foreground ownership' 5)
}
function Click-Control($Element, [int]$AppProcessId) {
    if ([Villa1849Native]::ForegroundProcessId() -ne $AppProcessId) { throw 'Refusing input outside the owned VC3D process.' }
    $current = $Element.Current
    if (!$current.IsEnabled -or $current.IsOffscreen) { throw "Control unavailable: $($current.Name)" }
    $rect = $current.BoundingRectangle
    if ($rect.Width -lt 2 -or $rect.Height -lt 2) { throw 'Control has no usable on-screen rectangle.' }
    [Villa1849Native]::Click([int]($rect.Left + $rect.Width/2), [int]($rect.Top + $rect.Height/2))
}
function Type-Into($Element, [string]$Text, [int]$AppProcessId) {
    Click-Control $Element $AppProcessId
    $Element.SetFocus()
    if ([Villa1849Native]::ForegroundProcessId() -ne $AppProcessId) { throw 'VC3D lost foreground before typing.' }
    [Villa1849Native]::SelectAll()
    [Villa1849Native]::Text($Text)
    [void](Wait-For { (Get-EditValue $Element) -ceq $Text } 'actual typed text readback' 10)
}
function Capture-OwnedWindow([int]$AppProcessId, [string]$Path) {
    $desktop = [Windows.Forms.SystemInformation]::VirtualScreen
    $condition = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty, $AppProcessId)
    $windows = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $condition)
    $bounds = New-Object 'System.Collections.Generic.List[object]'
    foreach ($window in $windows) {
        try {
            $c = $window.Current
            $r = $c.BoundingRectangle
            if (!$c.IsOffscreen -and $c.NativeWindowHandle -ne 0 -and $r.Width -ge 2 -and $r.Height -ge 2) {
                $bounds.Add(@{name=$c.Name;left=$r.Left;top=$r.Top;right=$r.Right;bottom=$r.Bottom})
            }
        } catch [Windows.Automation.ElementNotAvailableException] { }
    }
    if ($bounds.Count -eq 0) { throw 'No visible owned VC3D top-level window to capture.' }
    $left = [Math]::Max($desktop.Left, [Math]::Floor(($bounds | Measure-Object left -Minimum).Minimum))
    $top = [Math]::Max($desktop.Top, [Math]::Floor(($bounds | Measure-Object top -Minimum).Minimum))
    $right = [Math]::Min($desktop.Right, [Math]::Ceiling(($bounds | Measure-Object right -Maximum).Maximum))
    $bottom = [Math]::Min($desktop.Bottom, [Math]::Ceiling(($bounds | Measure-Object bottom -Maximum).Maximum))
    $width = [int]($right - $left)
    $height = [int]($bottom - $top)
    if ($width -lt 2 -or $height -lt 2) { throw 'Owned application bounds are outside the visible desktop.' }
    $bitmap = New-Object Drawing.Bitmap($width, $height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen([int]$left, [int]$top, 0, 0, $bitmap.Size)
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    return @{process_id=$AppProcessId;left=$left;top=$top;width=$width;height=$height;owned_windows=$bounds.ToArray();scope='Owned VC3D top-level main/modal window bounds only'}
}
function Save-UiSnapshot([int]$AppProcessId, [string]$Path) {
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($element in (Get-OwnedElements $AppProcessId)) {
        if ($rows.Count -ge 800) { break }
        try {
            $c = $element.Current
            if ($c.IsOffscreen) { continue }
            $rows.Add([ordered]@{name=$c.Name;automation_id=$c.AutomationId;type=$c.ControlType.ProgrammaticName;enabled=$c.IsEnabled;bounds=$c.BoundingRectangle.ToString()})
        } catch [Windows.Automation.ElementNotAvailableException] { }
    }
    Write-Json $rows.ToArray() $Path
}
function Snapshot([int]$AppProcessId, [string]$Directory, [string]$Label) {
    $capture = Capture-OwnedWindow $AppProcessId (Join-Path $Directory "$Label.png")
    Write-Json $capture (Join-Path $Directory "$Label.capture.json")
    Save-UiSnapshot $AppProcessId (Join-Path $Directory "$Label.ui.json")
}
function Normalize-Local([string]$Path) {
    return [IO.Path]::GetFullPath($Path.Replace('/','\')).TrimEnd('\')
}
function Read-Project([string]$Path) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    # A GUI save can briefly expose a file that is still being written. Poll
    # again; an invalid final project never satisfies the bounded success check.
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
    catch {
        Write-Json @{utc=[DateTime]::UtcNow.ToString('o');path=$Path;error=$_.ToString();policy='Retained last read/parse issue; bounded project polling still determines success or failure.'} (Join-Path $EvidenceDirectory 'last-project-read-issue.json')
        return $null
    }
}
function Get-SegmentLocations($Project) {
    foreach ($entry in @($Project.segments)) {
        if ($entry -is [string]) { $entry } else { $entry.location }
    }
}
function Is-Attached($Project, [string]$Expected) {
    if (!$Project) { return $false }
    foreach ($property in @('segments','output_segments','volumes')) {
        if (!$Project.PSObject.Properties[$property]) { return $false }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Project.output_segments)) { return $false }
    $locations = @(Get-SegmentLocations $Project)
    return $locations.Count -eq 1 -and (Normalize-Local $locations[0]) -ieq $Expected -and (Normalize-Local $Project.output_segments) -ieq $Expected -and @($Project.volumes).Count -eq 0
}
function Close-OwnedApp {
    if (!$script:OwnedProcess) { return }
    $app = $script:OwnedProcess
    try {
        $app.Refresh()
        if (!$app.HasExited) {
            [void][Villa1849Native]::PostMessage($app.MainWindowHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
            if (!$app.WaitForExit(5000)) { Stop-Process -Id $app.Id -Force; $app.WaitForExit(5000) | Out-Null }
        }
    } finally { $script:OwnedProcess = $null; $app.Dispose() }
}
function Open-MenuAction($MainWindow, [int]$AppProcessId, [string]$Action) {
    Focus-Window $MainWindow $AppProcessId
    $file = Wait-For { Find-Control $AppProcessId 'File' 'MenuItem' $MainWindow } 'File menu'
    Click-Control $file $AppProcessId
    $item = Wait-For { Find-Control $AppProcessId $Action 'MenuItem' } "File > $Action"
    Click-Control $item $AppProcessId
}
function Run-Case([string]$Label, [string]$Exe, [bool]$ShouldAttach, [string]$UncPath, [string]$FileUri, [string]$SegmentId) {
    $directory = Join-Path $EvidenceDirectory $Label
    if (Test-Path -LiteralPath $directory) { throw "Case directory already exists; refusing to overwrite evidence: $directory" }
    [void][IO.Directory]::CreateDirectory($directory)
    $projectPath = Join-Path $directory "$Label.volpkg.json"
    if (!(Test-Path -LiteralPath $Exe -PathType Leaf)) { throw "Missing exact installed executable: $Exe" }
    Record 'launch' @{case=$Label;exe=$Exe;sha256=(Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash;arguments=@()}
    $script:OwnedProcess = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru -RedirectStandardOutput (Join-Path $directory 'app.stdout.log') -RedirectStandardError (Join-Path $directory 'app.stderr.log')
    $appProcessId = $script:OwnedProcess.Id
    try {
        $main = Wait-For {
            $script:OwnedProcess.Refresh()
            if ($script:OwnedProcess.MainWindowHandle -ne 0) { [Windows.Automation.AutomationElement]::FromHandle($script:OwnedProcess.MainWindowHandle) }
        } 'VC3D main window' 60
        Open-MenuAction $main $appProcessId 'New Project'
        $saveDialog = Wait-For { Find-Control $appProcessId 'New Project' 'Window' } 'New Project dialog'
        Focus-Window $saveDialog $appProcessId
        $fileEdit = Wait-For {
            $edits = @(Get-OwnedElements $appProcessId $saveDialog | Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Edit -and !$_.Current.IsOffscreen })
            $matchingEdits = @($edits | Where-Object { $_.Current.AutomationId -eq 'fileNameEdit' -or (Clean-Name $_.Current.Name) -in @('File name:', 'File name') })
            if ($matchingEdits.Count -eq 1) { return $matchingEdits[0] }
            $matchingEdits = @($edits | Where-Object { (Get-EditValue $_) -eq 'untitled.volpkg.json' })
            if ($matchingEdits.Count -eq 1) { return $matchingEdits[0] }
        } 'source-identified project filename edit'
        Type-Into $fileEdit $projectPath $appProcessId
        Snapshot $appProcessId $directory '01-new-project'
        $saveButton = Wait-For { Find-Control $appProcessId 'Save' 'Button' $saveDialog } 'project Save button'
        Click-Control $saveButton $appProcessId
        $empty = Wait-For {
            $candidate = Read-Project $projectPath
            if ($candidate -and $candidate.PSObject.Properties['volumes'] -and $candidate.PSObject.Properties['segments']) { return $candidate }
        } 'actual application-created project'
        if (@($empty.volumes).Count -ne 0 -or @($empty.segments).Count -ne 0) { throw 'New Project did not produce a genuine empty project.' }
        Copy-Item -LiteralPath $projectPath -Destination (Join-Path $directory 'project-before.json')
        Record 'empty_project_created_by_gui' @{case=$Label;path=$projectPath}
        Open-MenuAction $main $appProcessId 'Attach Segments'
        $attachDialog = Wait-For { Find-Control $appProcessId 'Attach Segments' 'Window' } 'actual Attach Segments dialog'
        Focus-Window $attachDialog $appProcessId
        $pathEdit = Wait-For {
            $edits = @(Get-OwnedElements $appProcessId $attachDialog | Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Edit -and !$_.Current.IsOffscreen })
            if ($edits.Count -eq 1) { return $edits[0] }
        } 'single path edit in Attach Segments'
        Type-Into $pathEdit $FileUri $appProcessId
        Snapshot $appProcessId $directory '02-typed-identical-unc-uri'
        Record 'typed_uri_read_back' @{case=$Label;uri=(Get-EditValue $pathEdit)}
        $openButton = Wait-For { Find-Control $appProcessId 'Open' 'Button' $attachDialog } 'actual Open button'
        Click-Control $openButton $appProcessId
        if (!$ShouldAttach) {
            $failure = Wait-For {
                foreach ($node in (Get-OwnedElements $appProcessId $attachDialog)) {
                    if ($node.Current.Name.StartsWith('No such path:')) { return $node.Current.Name }
                }
                if (Is-Attached (Read-Project $projectPath) $UncPath) { throw 'Baseline unexpectedly attached the URI; this is not a failing before case.' }
            } 'baseline visible No such path result'
            Snapshot $appProcessId $directory '03-baseline-path-error'
            $after = Read-Project $projectPath
            if (@($after.segments).Count -ne 0 -or @($after.volumes).Count -ne 0) { throw 'Baseline changed the empty project unexpectedly.' }
            Copy-Item -LiteralPath $projectPath -Destination (Join-Path $directory 'project-after.json')
            $cancel = Wait-For { Find-Control $appProcessId 'Cancel' 'Button' $attachDialog } 'baseline Cancel button'
            Click-Control $cancel $appProcessId
            Record 'baseline_observed_failure' @{message=$failure;segments=0;volumes=0}
            return @{case=$Label;outcome='visible_path_error';message=$failure;segments=0;volumes=0}
        }
        [void](Wait-For {
            $warning = Find-Control $appProcessId 'Attach failed' 'Window'
            if ($warning) { throw 'The accepted application reported Attach failed.' }
            Is-Attached (Read-Project $projectPath) $UncPath
        } 'persisted real UNC segment attachment' 45)
        $row = Wait-For { Find-Control $appProcessId $SegmentId } 'actual public segment row' 45
        Focus-Window $main $appProcessId
        Click-Control $row $appProcessId
        $selected = Wait-For {
            $node = $row
            for ($depth=0; $depth -lt 4 -and $node; $depth++) {
                $pattern = $null
                if ($node.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
                    if (([Windows.Automation.SelectionItemPattern]$pattern).Current.IsSelected) { return $true }
                }
                $node = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($node)
            }
            return $false
        } 'selected rendered segment row' 10
        Snapshot $appProcessId $directory '03-accepted-attached-selected'
        Copy-Item -LiteralPath $projectPath -Destination (Join-Path $directory 'project-after.json')
        $project = Read-Project $projectPath
        if (!(Is-Attached $project $UncPath)) { throw 'Persisted project changed after selection.' }
        Record 'accepted_observed_attachment' @{segment_id=$SegmentId;selected=$selected;segments=@(Get-SegmentLocations $project);output_segments=$project.output_segments;volumes=@($project.volumes).Count}
        return @{case=$Label;outcome='attached_and_selected';segment_id=$SegmentId;selected=$selected;segments=@(Get-SegmentLocations $project);output_segments=$project.output_segments;volumes=0}
    } catch {
        try { Snapshot $appProcessId $directory 'failure' } catch { }
        $_.ToString() | Set-Content -LiteralPath (Join-Path $directory 'failure.txt') -Encoding UTF8
        throw
    } finally { Close-OwnedApp }
}

try {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run with Windows PowerShell -STA.' }
    if (![Environment]::UserInteractive) { throw 'No interactive desktop; no desktop/session provisioning will be attempted.' }
    $inputDesktop = [Villa1849Native]::OpenInputDesktop(0, $false, 1)
    if ($inputDesktop -eq [IntPtr]::Zero) { throw 'Existing input desktop is inaccessible.' }
    [void][Villa1849Native]::CloseDesktop($inputDesktop)
    $localDirectory = [IO.Path]::GetFullPath($SegmentDirectory).TrimEnd('\')
    if ($localDirectory -notmatch '^([A-Za-z]):\\(.+)$') { throw 'Segment directory must be an existing local drive directory.' }
    $drive = $Matches[1].ToUpperInvariant()
    $relative = $Matches[2]
    $uncPath = '\\localhost\' + $drive + '$\' + $relative
    if (!(Test-Path -LiteralPath $localDirectory -PathType Container)) { throw 'Local segment destination does not exist.' }
    if (!(Test-Path -LiteralPath $uncPath -PathType Container)) { throw 'Existing localhost administrative share is unavailable; no share, firewall or policy change will be attempted.' }
    $uriTail = (($relative -split '\\' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
    $fileUri = 'file://localhost/' + $drive + '$/' + $uriTail + '/'
    $root = [Windows.Automation.AutomationElement]::RootElement
    if (!$root -or $root.Current.ControlType -ne [Windows.Automation.ControlType]::Pane) { throw 'UI Automation desktop root is unavailable.' }
    $preflightName = if ($PreflightOnly) { 'preflight' } else { 'runtime-preflight' }
    $desktopSize = [Windows.Forms.SystemInformation]::VirtualScreen
    if ($desktopSize.Width -lt 640 -or $desktopSize.Height -lt 480) { throw 'No usable interactive desktop dimensions.' }
    Write-Json @{utc=[DateTime]::UtcNow.ToString('o');interactive=$true;existing_unc_access=$true;local_path=$localDirectory;unc_path=$uncPath;typed_uri=$fileUri;desktop_changes=$false;capture_scope='No desktop image retained before an owned VC3D window exists.'} (Join-Path $EvidenceDirectory "$preflightName.json")
    if ($PreflightOnly) { exit 0 }
    if (!$BaselineExe -or !$AcceptedExe -or !$InputManifest) { throw 'Normal mode requires both executables and the input manifest.' }
    Copy-Item -LiteralPath $InputManifest -Destination (Join-Path $EvidenceDirectory 'input-provenance.json')
    $metadata = Get-Content -LiteralPath (Join-Path $localDirectory 'meta.json') -Raw | ConvertFrom-Json
    $segmentId = [string]$metadata.uuid
    if ([string]::IsNullOrWhiteSpace($segmentId)) { throw 'Real input metadata has no segment UUID.' }
    foreach ($file in @('meta.json','x.tif','y.tif','z.tif')) {
        $localHash = (Get-FileHash -LiteralPath (Join-Path $localDirectory $file) -Algorithm SHA256).Hash
        $uncHash = (Get-FileHash -LiteralPath (Join-Path $uncPath $file) -Algorithm SHA256).Hash
        if ($localHash -cne $uncHash) { throw "Existing UNC access does not resolve the exact same $file bytes." }
        Record 'same_local_and_unc_input' @{file=$file;sha256=$localHash}
    }
    $baseline = Run-Case 'baseline' $BaselineExe $false $uncPath $fileUri $segmentId
    $accepted = Run-Case 'accepted-merge' $AcceptedExe $true $uncPath $fileUri $segmentId
    Write-Json @{status='paired_gui_observation_complete';baseline=$baseline;accepted=$accepted;typed_uri=$fileUri;segment_id=$segmentId;scope='GUI attachment and selected surface registration; no scan volume, geometry rendering, WSL access, newly recovered text, prize eligibility or payment demonstrated.'} (Join-Path $EvidenceDirectory 'result.json')
    exit 0
} catch {
    Write-Json @{status='stopped';utc=[DateTime]::UtcNow.ToString('o');error=$_.ToString();no_provisioning=$true} (Join-Path $EvidenceDirectory 'stopped.json')
    if ($script:OwnedProcess) {
        try { [void](Capture-OwnedWindow $script:OwnedProcess.Id (Join-Path $EvidenceDirectory 'stopped-owned-app.png')) } catch { }
    }
    Close-OwnedApp
    Write-Error $_
    exit 1
}
