# Run in the signed-in Windows session, against the installed development client.
$ErrorActionPreference = 'Stop'
$root='C:/Users/billy/socketagent-windows-build'
Remove-Item "$root/window-test-error.txt", "$root/window-test-results.json" -ErrorAction SilentlyContinue
trap { $_ | Out-String | Set-Content "$root/window-test-error.txt"; exit 1 }
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DesktopTest {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
 [StructLayout(LayoutKind.Sequential)] public struct PLACEMENT { public uint length,flags,showCmd; public POINT min,max; public RECT normal; }
 [StructLayout(LayoutKind.Sequential)] public struct ICONID { public uint cbSize; public IntPtr hwnd; public uint id; public Guid guid; }
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls,string title);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
 [StructLayout(LayoutKind.Sequential)] public struct MONITOR { public uint size; public RECT monitor,work; public uint flags; }
 [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd,uint flags);
 [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor,ref MONITOR info);
 public static RECT WorkArea(IntPtr hwnd) { var m=new MONITOR{size=(uint)Marshal.SizeOf(typeof(MONITOR))}; GetMonitorInfo(MonitorFromWindow(hwnd,2),ref m);return m.work; }
 [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd,out RECT r);
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd,out RECT r);
 [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr hwnd,ref PLACEMENT p);
 [DllImport("user32.dll")] public static extern bool SetWindowPlacement(IntPtr hwnd,ref PLACEMENT p);
 [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd,int index);
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hwnd,int x,int y,int width,int height,bool repaint);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd,int cmd);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd,uint msg,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd,uint msg,IntPtr w,IntPtr l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessage(string name);
 [DllImport("user32.dll")] static extern IntPtr FindWindowEx(IntPtr parent,IntPtr after,string cls,string title);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd,IntPtr dc,uint flags);
 [DllImport("shell32.dll")] static extern int Shell_NotifyIconGetRect(ref ICONID id,out RECT rect);
 public static IntPtr Child(IntPtr parent) { return FindWindowEx(parent,IntPtr.Zero,null,null); }
 public static bool HasTrayIcon(IntPtr hwnd) { var id=new ICONID{cbSize=(uint)Marshal.SizeOf(typeof(ICONID)),hwnd=hwnd,id=1}; RECT rect; return Shell_NotifyIconGetRect(ref id,out rect)>=0; }
 public static PLACEMENT Placement(IntPtr hwnd) { var p=new PLACEMENT{length=(uint)Marshal.SizeOf(typeof(PLACEMENT))}; GetWindowPlacement(hwnd,ref p);return p; }
 public static int Hit(IntPtr hwnd,int x,int y) { return SendMessage(hwnd,0x84,IntPtr.Zero,new IntPtr((y<<16)|(x&0xffff))).ToInt32(); }
}
'@
$exe=Join-Path $env:LOCALAPPDATA 'SocketAgentDesktop/socketagent.exe'
$script:checks=[Collections.Generic.List[string]]::new()
function Assert-Window($condition,$name) {
 if (!$condition) { throw "FAILED: $name" }
 $script:checks.Add($name)
 $script:checks | ConvertTo-Json | Set-Content "$root/window-test-results.json"
}
function Find-App {
 $script:window=[DesktopTest]::FindWindow('SOCKETAGENT_DESKTOP_WINDOW',[NullString]::Value)
 if($script:window -eq [IntPtr]::Zero){throw 'App window not found'}
 $script:child=[DesktopTest]::Child($script:window)
}
function Capture-App($name) {
 $r=New-Object DesktopTest+RECT
 [DesktopTest]::GetWindowRect($script:window,[ref]$r)|Out-Null
 $bitmap=New-Object System.Drawing.Bitmap(($r.Right-$r.Left),($r.Bottom-$r.Top))
 $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
 $dc=$graphics.GetHdc()
 [DesktopTest]::PrintWindow($script:window,$dc,2)|Out-Null
 $graphics.ReleaseHdc($dc)
 $bitmap.Save("$root/$name.png")
 $graphics.Dispose();$bitmap.Dispose()
}
function Click-Control($rightOffset) {
 $r=New-Object DesktopTest+RECT
 [DesktopTest]::GetClientRect($script:window,[ref]$r)|Out-Null
 $point=[IntPtr]((22 -shl 16) -bor ($r.Right-$rightOffset))
 [DesktopTest]::PostMessage($script:child,0x200,[IntPtr]::Zero,$point)|Out-Null
 [DesktopTest]::PostMessage($script:child,0x201,[IntPtr]1,$point)|Out-Null
 [DesktopTest]::PostMessage($script:child,0x202,[IntPtr]::Zero,$point)|Out-Null
 Start-Sleep -Milliseconds 700
}
function Open-App {
 [DesktopTest]::PostMessage($script:window,[DesktopTest]::RegisterWindowMessage('SocketAgent.Desktop.Activate.v1'),[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
 Start-Sleep -Milliseconds 500
}
function Restart-App {
 $process=Get-Process socketagent | Where-Object Path -eq $exe | Select-Object -First 1
 Start-Process $exe -ArgumentList '--quit' -Wait
 if (!$process.WaitForExit(10000)) { throw 'Explicit Quit failed' }
 Start-Process $exe -WorkingDirectory (Split-Path $exe)
 Start-Sleep -Seconds 8
 Find-App
}
Find-App
$original=[DesktopTest]::Placement($window)
try {
Assert-Window (([DesktopTest]::GetWindowLong($window,-16) -band 0x00c00000) -eq 0) 'Stock caption removed'
Assert-Window ([DesktopTest]::HasTrayIcon($window)) 'Tray icon registered with Windows'
[DesktopTest]::ShowWindow($window,9)|Out-Null
[DesktopTest]::MoveWindow($window,200,120,1100,760,$true)|Out-Null
[DesktopTest]::PostMessage($window,0x232,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
Start-Sleep -Seconds 1
Assert-Window ([DesktopTest]::Hit($window,500,142) -eq 2) 'Title bar drags through native caption handling'
Assert-Window ([DesktopTest]::Hit($window,202,122) -eq 13) 'Corner resize hit testing'
Assert-Window ([DesktopTest]::Hit($child,500,142) -eq -1) 'Flutter child delegates caption input'
Assert-Window ([DesktopTest]::Hit($child,1277,142) -eq 1) 'Custom controls receive Flutter input'
Click-Control 115
Assert-Window ([DesktopTest]::IsIconic($window)) 'Custom minimize control'
Open-App
Click-Control 69
Assert-Window ([DesktopTest]::IsZoomed($window)) 'Custom maximize control'
$maximizedBounds=New-Object DesktopTest+RECT
[DesktopTest]::GetWindowRect($window,[ref]$maximizedBounds)|Out-Null
$work=[DesktopTest]::WorkArea($window)
Assert-Window ($maximizedBounds.Left -ge $work.Left -and $maximizedBounds.Top -ge $work.Top -and $maximizedBounds.Right -le $work.Right -and $maximizedBounds.Bottom -le $work.Bottom) 'Maximized outer window leaves the Windows taskbar visible'
Click-Control 69
Assert-Window (![DesktopTest]::IsZoomed($window)) 'Custom restore control'
Click-Control 23
Assert-Window (![DesktopTest]::IsWindowVisible($window)) 'Custom hide control keeps the client in the tray'
Assert-Window ([DesktopTest]::HasTrayIcon($window)) 'Tray registration survives hiding'
[DesktopTest]::PostMessage($window,0x8029,[IntPtr]::Zero,[IntPtr]0x202)|Out-Null
Start-Sleep -Milliseconds 500
Assert-Window ([DesktopTest]::IsWindowVisible($window)) 'Mouse tray click restores the window'
Click-Control 23
[uint32]$firstPid=0
[DesktopTest]::GetWindowThreadProcessId($window,[ref]$firstPid)|Out-Null
Start-Process $exe -WorkingDirectory (Split-Path $exe) -Wait
Start-Sleep -Milliseconds 500
Find-App
[uint32]$secondPid=0
[DesktopTest]::GetWindowThreadProcessId($window,[ref]$secondPid)|Out-Null
Assert-Window ($firstPid -eq $secondPid -and [DesktopTest]::IsWindowVisible($window)) 'Shortcut restores the existing process'
[DesktopTest]::PostMessage($window,0x112,[IntPtr]0xf060,[IntPtr]::Zero)|Out-Null
Start-Sleep -Milliseconds 500
Assert-Window (![DesktopTest]::IsWindowVisible($window)) 'Alt-F4 hides instead of exiting'
[DesktopTest]::PostMessage($window,0x8029,[IntPtr]::Zero,[IntPtr]0x400)|Out-Null
Start-Sleep -Milliseconds 500
Assert-Window ([DesktopTest]::IsWindowVisible($window)) 'Tray selection restores the window'
Restart-App
$r=New-Object DesktopTest+RECT
[DesktopTest]::GetWindowRect($window,[ref]$r)|Out-Null
Assert-Window ($r.Left -eq 200 -and $r.Top -eq 120 -and ($r.Right-$r.Left) -eq 1100 -and ($r.Bottom-$r.Top) -eq 760) 'Position and size survive explicit Quit and relaunch'
Click-Control 69
Start-Sleep -Milliseconds 500
Restart-App
Assert-Window ([DesktopTest]::IsZoomed($window)) 'Maximized state survives explicit Quit and relaunch'
Click-Control 69
$r=New-Object DesktopTest+RECT
[DesktopTest]::GetWindowRect($window,[ref]$r)|Out-Null
Assert-Window (($r.Right-$r.Left) -eq 1100 -and ($r.Bottom-$r.Top) -eq 760) 'Restore size is retained while maximized'
} finally {
 [DesktopTest]::SetWindowPlacement($window,[ref]$original)|Out-Null
}
Start-Sleep -Seconds 1
Capture-App 'desktop-window-final'
$p=Get-Process socketagent | Where-Object Path -eq $exe | Select-Object -First 1
$p.Id | Set-Content "$root/desktop-test.pid"
[pscustomobject]@{Pid=$p.Id;Window=$window.ToInt64();Installed=$p.Path} | ConvertTo-Json | Set-Content "$root/desktop-smoke.json"
$script:checks | ConvertTo-Json
