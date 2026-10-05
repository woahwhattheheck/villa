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
    public sealed class WindowInfo {
        public IntPtr Handle; public string Title; public int Left, Top, Right, Bottom;
    }
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
    private delegate bool WindowCallback(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out RECT bounds);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int capacity);
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
    public static WindowInfo[] OwnedWindows(uint processId) {
        var windows = new System.Collections.Generic.List<WindowInfo>();
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            uint owner; GetWindowThreadProcessId(window, out owner);
            if (owner != processId || !IsWindowVisible(window)) return true;
            RECT bounds; if (!GetWindowRect(window, out bounds)) return true;
            var title = new System.Text.StringBuilder(512); GetWindowText(window, title, title.Capacity);
            var info = new WindowInfo(); info.Handle=window; info.Title=title.ToString();
            info.Left=bounds.Left; info.Top=bounds.Top; info.Right=bounds.Right; info.Bottom=bounds.Bottom;
            windows.Add(info); return true;
        }, IntPtr.Zero);
        return windows.ToArray();
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
    public static void Press(ushort key) { Send(new INPUT[] {Key(key,false),Key(key,true)}); }
    public static void AltFile() { Send(new INPUT[] {Key(0x12,false),Key(0x46,false),Key(0x46,true),Key(0x12,true)}); }
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
    # Qt menu popups are separate native top-level windows. Scope each UIA
    # subtree through a Win32-verified process-owned handle, including the root.
    if ($Root) {
        $Root
        $Root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        return
    }
    foreach ($native in [Villa1849Native]::OwnedWindows($AppProcessId)) {
        try {
            $ownedRoot = [Windows.Automation.AutomationElement]::FromHandle($native.Handle)
            $ownedRoot
            $ownedRoot.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        } catch [Windows.Automation.ElementNotAvailableException] { }
    }
}
function Clean-Name([string]$Name) { return (($Name -split "`t",2)[0].Replace('&','') -replace '\.{3}$|\u2026$','').Trim() }
function Get-ControlTypeName($Current) {
    if (!$Current -or !$Current.PSObject.Properties['ControlType']) { return '' }
    try {
        $controlType = $Current.ControlType
        if (!$controlType) { return '' }
        $programmaticName = $controlType.PSObject.Properties['ProgrammaticName']
        if ($programmaticName) { return [string]$programmaticName.Value }
        return [string]$controlType
    } catch { return '' }
}
function Matches-ControlType($Current, [string]$Type) {
    if (!$Current -or !$Current.PSObject.Properties['ControlType']) { return $false }
    $field = [Windows.Automation.ControlType].GetField($Type, [Reflection.BindingFlags]'Public,Static')
    if (!$field) { throw "Unknown UI Automation control type: $Type" }
    return $Current.ControlType -eq $field.GetValue($null)
}
function Find-Control([int]$AppProcessId, [string]$Name, [string]$Type='', $Root=$null) {
    foreach ($element in (Get-OwnedElements $AppProcessId $Root)) {
        try {
            $current = $element.Current
            if ($current.IsOffscreen) { continue }
            if ($Type -and !(Matches-ControlType $current $Type)) { continue }
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
    [void](Wait-For { [Villa1849Native]::GetForegroundWindow() -eq $handle -and [Villa1849Native]::ForegroundProcessId() -eq $AppProcessId } 'exact VC3D window foreground' 5)
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
function Capture-OperationalControl([int]$AppProcessId, $Target, [string]$Path) {
    if (!$Target) { throw 'No explicit operational control capture target supplied.' }
    $c = $Target.Current
    $name = Clean-Name $c.Name
    $allowedDialog = $c.ControlType -eq [Windows.Automation.ControlType]::Window -and $name -in @('New Project','Attach Segments')
    $allowedTree = $c.ControlType -eq [Windows.Automation.ControlType]::Tree
    if (!$allowedDialog -and !$allowedTree) { throw 'Capture is restricted to operational project/attachment dialogs or the segment tree.' }
    $ancestor = $Target
    $owned = $false
    for ($depth=0; $depth -lt 30 -and $ancestor; $depth++) {
        $handle = [IntPtr]$ancestor.Current.NativeWindowHandle
        if ($handle -ne [IntPtr]::Zero) {
            [uint32]$owner = 0
            [void][Villa1849Native]::GetWindowThreadProcessId($handle, [ref]$owner)
            if ($owner -eq $AppProcessId) { $owned=$true; break }
        }
        $ancestor = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($ancestor)
    }
    if (!$owned -or $c.IsOffscreen) { throw 'Capture target is not a visible owned application control.' }
    $desktop = [Windows.Forms.SystemInformation]::VirtualScreen
    $rect = $c.BoundingRectangle
    $left = [Math]::Max($desktop.Left, [Math]::Floor($rect.Left))
    $top = [Math]::Max($desktop.Top, [Math]::Floor($rect.Top))
    $right = [Math]::Min($desktop.Right, [Math]::Ceiling($rect.Right))
    $bottom = [Math]::Min($desktop.Bottom, [Math]::Ceiling($rect.Bottom))
    $width = [int]($right - $left)
    $height = [int]($bottom - $top)
    if ($width -lt 2 -or $height -lt 2) { throw 'Owned application bounds are outside the visible desktop.' }
    $bitmap = New-Object Drawing.Bitmap($width, $height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen([int]$left, [int]$top, 0, 0, $bitmap.Size)
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    return @{process_id=$AppProcessId;left=$left;top=$top;width=$width;height=$height;control_name=$name;automation_id=$c.AutomationId;scope='Actual operational dialog or segment-tree pixels only; no viewer/geometry capture'}
}
function Save-UiSnapshot([int]$AppProcessId, [string]$Path) {
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($element in (Get-OwnedElements $AppProcessId)) {
        if ($rows.Count -ge 800) { break }
        try {
            $c = $element.Current
            if ($c.IsOffscreen) { continue }
            $rows.Add([ordered]@{name=$c.Name;automation_id=$c.AutomationId;type=(Get-ControlTypeName $c);process_id=$c.ProcessId;native_handle=$c.NativeWindowHandle;enabled=$c.IsEnabled;bounds=$c.BoundingRectangle.ToString()})
        } catch [Windows.Automation.ElementNotAvailableException] { }
    }
    Write-Json $rows.ToArray() $Path
}
function Get-UiIdentity($Element) {
    try {
        $c = $Element.Current
        $value = $null
        $valuePattern = $null
        if ($Element.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)) {
            try { $value = ([Windows.Automation.ValuePattern]$valuePattern).Current.Value } catch { }
        }
        return [ordered]@{
            name=[string]$c.Name
            automation_id=[string]$c.AutomationId
            help_text=[string]$c.HelpText
            value=[string]$value
            type=(Get-ControlTypeName $c)
            process_id=$c.ProcessId
            native_handle=$c.NativeWindowHandle
            offscreen=$c.IsOffscreen
            enabled=$c.IsEnabled
            bounds=$c.BoundingRectangle.ToString()
        }
    } catch [Windows.Automation.ElementNotAvailableException] { return $null }
}
function Find-ExactIdentityControl([int]$AppProcessId, [string]$Identity) {
    foreach ($element in (Get-OwnedElements $AppProcessId)) {
        $fields = Get-UiIdentity $element
        if (!$fields -or $fields.offscreen) { continue }
        if ($fields.name -ceq $Identity -or $fields.automation_id -ceq $Identity -or $fields.help_text -ceq $Identity -or $fields.value -ceq $Identity) {
            return $element
        }
    }
    return $null
}
function Save-UiTreeDiagnostic([int]$AppProcessId, [string]$Path, [int]$Limit=2000) {
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $walker = [Windows.Automation.TreeWalker]::RawViewWalker
    $stack = New-Object System.Collections.Stack
    foreach ($native in [Villa1849Native]::OwnedWindows($AppProcessId)) {
        try {
            $root = [Windows.Automation.AutomationElement]::FromHandle($native.Handle)
            $stack.Push([ordered]@{element=$root;depth=0;parent_index=$null})
        } catch [Windows.Automation.ElementNotAvailableException] { }
    }
    while ($stack.Count -gt 0 -and $rows.Count -lt $Limit) {
        $entry = $stack.Pop()
        $element = $entry.element
        $fields = Get-UiIdentity $element
        if (!$fields -or $fields.process_id -ne $AppProcessId) { continue }
        $index = $rows.Count
        $supported = New-Object 'System.Collections.Generic.List[string]'
        foreach ($pattern in @(
            @{name='Invoke';id=[Windows.Automation.InvokePattern]::Pattern},
            @{name='SelectionItem';id=[Windows.Automation.SelectionItemPattern]::Pattern},
            @{name='Value';id=[Windows.Automation.ValuePattern]::Pattern},
            @{name='ExpandCollapse';id=[Windows.Automation.ExpandCollapsePattern]::Pattern},
            @{name='ScrollItem';id=[Windows.Automation.ScrollItemPattern]::Pattern}
        )) {
            $candidatePattern = $null
            try {
                if ($element.TryGetCurrentPattern($pattern.id, [ref]$candidatePattern)) { $supported.Add($pattern.name) }
            } catch [Windows.Automation.ElementNotAvailableException] { }
        }
        $fields['index'] = $index
        $fields['parent_index'] = $entry.parent_index
        $fields['depth'] = $entry.depth
        $fields['patterns'] = $supported.ToArray()
        $rows.Add($fields)

        if ($entry.depth -ge 30) { continue }
        $children = New-Object 'System.Collections.Generic.List[object]'
        try {
            $child = $walker.GetFirstChild($element)
            while ($child) {
                $children.Add($child)
                $child = $walker.GetNextSibling($child)
            }
        } catch [Windows.Automation.ElementNotAvailableException] { }
        for ($i=$children.Count-1; $i -ge 0; $i--) {
            $stack.Push([ordered]@{element=$children[$i];depth=($entry.depth+1);parent_index=$index})
        }
    }
    Write-Json ([ordered]@{
        process_id=$AppProcessId
        generated_utc=[DateTime]::UtcNow.ToString('o')
        tree_view='RawViewWalker'
        element_limit=$Limit
        truncated=($stack.Count -gt 0)
        elements=$rows.ToArray()
    }) $Path
}
function Snapshot([int]$AppProcessId, [string]$Directory, [string]$Label, $CaptureTarget=$null, [switch]$BestEffort) {
    $errors = New-Object 'System.Collections.Generic.List[object]'
    try {
        $inventory = @([Villa1849Native]::OwnedWindows($AppProcessId) | ForEach-Object { @{handle=$_.Handle.ToInt64();title=$_.Title;left=$_.Left;top=$_.Top;right=$_.Right;bottom=$_.Bottom} })
        Write-Json $inventory (Join-Path $Directory "$Label.windows.json")
    } catch { $errors.Add(@{part='native_windows';error=$_.ToString()}) }
    try { Save-UiSnapshot $AppProcessId (Join-Path $Directory "$Label.ui.json") }
    catch { $errors.Add(@{part='uia';error=$_.ToString()}) }
    if ($CaptureTarget) {
        try {
            $capture = Capture-OperationalControl $AppProcessId $CaptureTarget (Join-Path $Directory "$Label.png")
            Write-Json $capture (Join-Path $Directory "$Label.capture.json")
        } catch { $errors.Add(@{part='capture';error=$_.ToString()}) }
    }
    Write-Json @{errors=$errors.ToArray();capture_requested=[bool]$CaptureTarget;scope='Independent native-window/UIA diagnostics; screenshots only for explicit operational controls.'} (Join-Path $Directory "$Label.diagnostics.json")
    if ($errors.Count -gt 0 -and !$BestEffort) { throw "Evidence diagnostics failed at $Label; see retained diagnostics.json" }
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
function Close-ObservedStartupCatalog([int]$AppProcessId, [string]$Directory) {
    foreach ($native in [Villa1849Native]::OwnedWindows($AppProcessId)) {
        if ($native.Title -ceq 'Open Data Catalog') {
            Snapshot $AppProcessId $Directory 'startup-catalog-observed' -BestEffort
            $catalog = [Windows.Automation.AutomationElement]::FromHandle($native.Handle)
            Focus-Window $catalog $AppProcessId
            $close = Wait-For { Find-Control $AppProcessId 'Close' 'Button' $catalog } 'observed catalog Close button' 10
            Click-Control $close $AppProcessId
            [void](Wait-For { @([Villa1849Native]::OwnedWindows($AppProcessId) | Where-Object { $_.Handle -eq $native.Handle }).Count -eq 0 } 'catalog dismissal' 10)
            Record 'closed_observed_startup_catalog' @{title=$native.Title;handle=$native.Handle.ToInt64();settings_changed=$false}
        }
    }
}
function Open-MenuAction($MainWindow, [int]$AppProcessId, [string]$Action, [string]$Directory) {
    Close-ObservedStartupCatalog $AppProcessId $Directory
    Focus-Window $MainWindow $AppProcessId
    $file = Wait-For { Find-Control $AppProcessId 'File' 'MenuItem' $MainWindow } 'File menu'
    if ($Action -notin @('New Project','Attach Segments')) { throw 'No source-mapped menu action.' }
    # Use the actual native menu keyboard path, not direct application calls.
    # Both pins put New Project first and Attach Segments fifth (separators
    # skipped). N is a duplicated mnemonic; Home is unambiguous.
    [Villa1849Native]::AltFile()
    Snapshot $AppProcessId $Directory ('menu-' + $Action.Replace(' ','') + '-opened') -BestEffort
    if ([Villa1849Native]::ForegroundProcessId() -ne $AppProcessId) { throw 'Owned app lost menu input focus.' }
    [Villa1849Native]::Press(0x24)
    if ($Action -eq 'Attach Segments') { for ($i=0; $i -lt 4; $i++) { [Villa1849Native]::Press(0x28) } }
    [Villa1849Native]::Press(0x0D)
    Record 'native_file_menu_action' @{action=$Action;path=$(if ($Action -eq 'New Project') {'Alt+F, Home, Enter'} else {'Alt+F, Home, Down x4, Enter'});result='Awaiting actual dialog; not yet success'}
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
    $captureTarget = $null
    try {
        $main = Wait-For {
            foreach ($native in [Villa1849Native]::OwnedWindows($appProcessId)) {
                if ($native.Title -ceq 'Open Data Catalog') { continue }
                $candidateWindow = [Windows.Automation.AutomationElement]::FromHandle($native.Handle)
                if (Find-Control $appProcessId 'File' 'MenuItem' $candidateWindow) { return $candidateWindow }
            }
        } 'owned VC3D main window with File menu' 60
        Snapshot $appProcessId $directory '00-startup' -BestEffort
        Open-MenuAction $main $appProcessId 'New Project' $directory
        $saveDialog = Wait-For { Find-Control $appProcessId 'New Project' 'Window' } 'New Project dialog'
        $captureTarget = $saveDialog
        Focus-Window $saveDialog $appProcessId
        $fileEdit = Wait-For {
            $edits = @(Get-OwnedElements $appProcessId $saveDialog | Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Edit -and !$_.Current.IsOffscreen })
            $matchingEdits = @($edits | Where-Object { $_.Current.AutomationId -eq 'fileNameEdit' -or (Clean-Name $_.Current.Name) -in @('File name:', 'File name') })
            if ($matchingEdits.Count -eq 1) { return $matchingEdits[0] }
            $matchingEdits = @($edits | Where-Object { (Get-EditValue $_) -eq 'untitled.volpkg.json' })
            if ($matchingEdits.Count -eq 1) { return $matchingEdits[0] }
        } 'source-identified project filename edit'
        Type-Into $fileEdit $projectPath $appProcessId
        Snapshot $appProcessId $directory '01-new-project' $captureTarget
        $saveButton = Wait-For { Find-Control $appProcessId 'Save' 'Button' $saveDialog } 'project Save button'
        Click-Control $saveButton $appProcessId
        $empty = Wait-For {
            $candidate = Read-Project $projectPath
            if ($candidate -and $candidate.PSObject.Properties['volumes'] -and $candidate.PSObject.Properties['segments']) { return $candidate }
        } 'actual application-created project'
        if (@($empty.volumes).Count -ne 0 -or @($empty.segments).Count -ne 0) { throw 'New Project did not produce a genuine empty project.' }
        Copy-Item -LiteralPath $projectPath -Destination (Join-Path $directory 'project-before.json')
        Record 'empty_project_created_by_gui' @{case=$Label;path=$projectPath}
        $captureTarget = $null
        Open-MenuAction $main $appProcessId 'Attach Segments' $directory
        $attachDialog = Wait-For { Find-Control $appProcessId 'Attach Segments' 'Window' } 'actual Attach Segments dialog'
        $captureTarget = $attachDialog
        Focus-Window $attachDialog $appProcessId
        $pathEdit = Wait-For {
            $edits = @(Get-OwnedElements $appProcessId $attachDialog | Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Edit -and !$_.Current.IsOffscreen })
            if ($edits.Count -eq 1) { return $edits[0] }
        } 'single path edit in Attach Segments'
        Type-Into $pathEdit $FileUri $appProcessId
        Snapshot $appProcessId $directory '02-typed-identical-unc-uri' $captureTarget
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
            Snapshot $appProcessId $directory '03-baseline-path-error' $captureTarget
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
        $captureTarget = $null
        Close-ObservedStartupCatalog $appProcessId $directory
        Focus-Window $main $appProcessId
        $volumePackage = Wait-For {
            foreach ($control in (Get-OwnedElements $appProcessId)) {
                try {
                    $current = $control.Current
                    if (!$current.IsOffscreen -and ([string]$current.Name).EndsWith('Volume Package', [StringComparison]::Ordinal)) { return $control }
                } catch [Windows.Automation.ElementNotAvailableException] { }
            }
        } 'collapsed Volume Package control' 10
        $invoke = $null
        if ($volumePackage.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) {
            ([Windows.Automation.InvokePattern]$invoke).Invoke()
            $panelMethod = 'UI Automation InvokePattern on actual Volume Package button'
        } else {
            Click-Control $volumePackage $appProcessId
            $panelMethod = 'native click on actual Volume Package button'
        }
        Record 'opened_volume_package_panel' @{control_name=(Clean-Name $volumePackage.Current.Name);method=$panelMethod;result='Awaiting actual segment row'}
        Start-Sleep -Milliseconds 750
        Save-UiTreeDiagnostic $appProcessId (Join-Path $directory 'volume-package-panel-tree.initial.json')
        function Get-SurfaceTree([int]$ProcessId) {
            foreach ($control in (Get-OwnedElements $ProcessId)) {
                try {
                    $current = $control.Current
                    if ($current.IsOffscreen) { continue }
                    if ($current.ControlType -ne [Windows.Automation.ControlType]::Tree) { continue }
                    if (([string]$current.AutomationId).EndsWith('treeWidgetSurfaces')) { return $control }
                } catch [Windows.Automation.ElementNotAvailableException] { }
            }
            return $null
        }
        function Get-SegmentationCombo([int]$ProcessId) {
            foreach ($control in (Get-OwnedElements $ProcessId)) {
                try {
                    $current = $control.Current
                    if ($current.IsOffscreen) { continue }
                    if ($current.ControlType -ne [Windows.Automation.ControlType]::ComboBox) { continue }
                    if (([string]$current.AutomationId).EndsWith('cmbSegmentationDir')) { return $control }
                } catch [Windows.Automation.ElementNotAvailableException] { }
            }
            return $null
        }
        # The startup catalog is a separate top-level window and covers the dock.
        # Dismiss it again before any Volume Package input so the click cannot land on the catalog.
        Close-ObservedStartupCatalog $appProcessId $directory
        Focus-Window $main $appProcessId
        if (!(Get-SurfaceTree $appProcessId)) {
            $toggle = Wait-For {
                foreach ($control in (Get-OwnedElements $appProcessId)) {
                    try {
                        $current = $control.Current
                        if (!$current.IsOffscreen -and ([string]$current.Name).EndsWith('Volume Package', [StringComparison]::Ordinal)) { return $control }
                    } catch [Windows.Automation.ElementNotAvailableException] { }
                }
            } 'Volume Package toggle after catalog dismissal' 10
            $invoke = $null
            if ($toggle.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) {
                ([Windows.Automation.InvokePattern]$invoke).Invoke()
            } else { Click-Control $toggle $appProcessId }
            Record 'reopened_volume_package_panel' @{reason='Surface tree was not visible after the first toggle'}
        }
        $reloadSurfaces = Wait-For { Find-Control $appProcessId 'Reload Surfaces' 'Button' } 'source-identified Reload Surfaces button' 10
        Focus-Window $main $appProcessId
        Click-Control $reloadSurfaces $appProcessId
        Record 'reloaded_surface_tree' @{control_name=(Clean-Name $reloadSurfaces.Current.Name);method='native click on exact visible Reload Surfaces button';result='Awaiting exposed segment registration'}
        Start-Sleep -Milliseconds 750
        Close-ObservedStartupCatalog $appProcessId $directory
        if (!(Get-SurfaceTree $appProcessId)) {
            Focus-Window $main $appProcessId
            $toggle = Wait-For {
                foreach ($control in (Get-OwnedElements $appProcessId)) {
                    try {
                        $current = $control.Current
                        if (!$current.IsOffscreen -and ([string]$current.Name).EndsWith('Volume Package', [StringComparison]::Ordinal)) { return $control }
                    } catch [Windows.Automation.ElementNotAvailableException] { }
                }
            } 'Volume Package toggle after reload' 10
            $invoke = $null
            if ($toggle.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) {
                ([Windows.Automation.InvokePattern]$invoke).Invoke()
            } else { Click-Control $toggle $appProcessId }
            Record 'restored_volume_package_panel' @{reason='Reload left the Volume Package dock collapsed'}
        }
        $directoryLeaf = Split-Path -Leaf $UncPath.TrimEnd('\','/')
        $registration = $null
        try {
            $registration = Wait-For {
                $exact = Find-ExactIdentityControl $appProcessId $SegmentId
                if ($exact) { return $exact }
                $combo = Get-SegmentationCombo $appProcessId
                if ($combo) {
                    $shown = [string](Get-EditValue $combo)
                    if ($shown -ceq $directoryLeaf -or $shown -ceq $SegmentId) { return $combo }
                }
                return $null
            } 'actual public segment registration in the Volume Package dock' 45
        } catch {
            Save-UiTreeDiagnostic $appProcessId (Join-Path $directory 'volume-package-panel-tree.timeout.json')
            Record 'segment_identity_not_exposed' @{segment_id=$SegmentId;directory_leaf=$directoryLeaf;searched_fields=@('Name','AutomationId','HelpText','Value','cmbSegmentationDir');diagnostic='volume-package-panel-tree.timeout.json';result='No visible exact identity or segmentation-directory registration'}
            throw
        }
        $registeredAs = if ($registration.Current.ControlType -eq [Windows.Automation.ControlType]::ComboBox) { Get-EditValue $registration } else { Clean-Name $registration.Current.Name }
        Record 'observed_segment_registration' @{segment_id=$SegmentId;directory_leaf=$directoryLeaf;shown=$registeredAs;control_type=(Get-ControlTypeName $registration.Current);automation_id=$registration.Current.AutomationId;surface_row_exposed=($registeredAs -ceq $SegmentId)}
        Focus-Window $main $appProcessId
        $captureTarget = $registration
        if ($registration.Current.ControlType -eq [Windows.Automation.ControlType]::ComboBox) {
            $surfaceTree = Get-SurfaceTree $appProcessId
            if ($surfaceTree) { $captureTarget = $surfaceTree }
        } else {
            Click-Control $registration $appProcessId
            $selected = Wait-For {
                $node = $registration
                for ($depth=0; $depth -lt 4 -and $node; $depth++) {
                    $pattern = $null
                    if ($node.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
                        if (([Windows.Automation.SelectionItemPattern]$pattern).Current.IsSelected) { return $true }
                    }
                    $node = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($node)
                }
                return $false
            } 'selected rendered segment row' 10
            $captureTarget = $registration
            for ($depth=0; $depth -lt 20 -and $captureTarget -and $captureTarget.Current.ControlType -ne [Windows.Automation.ControlType]::Tree; $depth++) {
                $captureTarget = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($captureTarget)
            }
        }
        if (!$captureTarget) { throw 'Segment registration has no identifiable operational control for evidence capture.' }
        Snapshot $appProcessId $directory '03-accepted-attached-selected' $captureTarget
        Copy-Item -LiteralPath $projectPath -Destination (Join-Path $directory 'project-after.json')
        $project = Read-Project $projectPath
        if (!(Is-Attached $project $UncPath)) { throw 'Persisted project changed after selection.' }
        Record 'accepted_observed_attachment' @{segment_id=$SegmentId;shown=$registeredAs;segments=@(Get-SegmentLocations $project);output_segments=$project.output_segments;volumes=@($project.volumes).Count}
        return @{case=$Label;outcome='attached_and_selected';segment_id=$SegmentId;shown=$registeredAs;segments=@(Get-SegmentLocations $project);output_segments=$project.output_segments;volumes=0}
    } catch {
        $originalFailure = $_
        try { Snapshot $appProcessId $directory 'failure' $captureTarget -BestEffort }
        catch { $_.ToString() | Set-Content -LiteralPath (Join-Path $directory 'failure-diagnostics-error.txt') -Encoding UTF8 }
        $originalFailure.ToString() | Set-Content -LiteralPath (Join-Path $directory 'failure.txt') -Encoding UTF8
        throw $originalFailure
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
    Close-OwnedApp
    Write-Error $_
    exit 1
}
