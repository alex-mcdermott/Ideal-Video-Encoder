# Ideal Video Encoder - WPF GUI (Windows 11 style)
# https://github.com/alex-mcdermott/Ideal-Video-Encoder
# SPDX-License-Identifier: GPL-3.0-or-later
# -------------------------------------------------------------------------------------------
# Requirements in PATH: ffmpeg.exe (with libx265, libsvtav1, zscale, libvmaf), ffprobe.exe, exiftool.exe
# Optional: mpv.net (the embedded preview uses its libmpv-2.dll)
# Output: <source folder | custom folder>\<subfolder>\<name>.MOV (HEVC) or .MP4 (AV1)  (settings are remembered)
# Clips passed on the command line (or dropped onto the .exe) are queued at startup.
# ASCII-only source: non-ASCII glyphs come from XML entities or [char] codes.

param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Paths)

# ========== Native helpers (C# 5 so Windows PowerShell 5.1 / ps2exe can compile it) ==========
$NativeSource = @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace IdealVE
{
    public class QueueItem : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        void Raise(string name) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(name)); }

        string _name, _path, _status, _statusKey, _detail, _info, _note = "";
        double _progress;

        public string Name { get { return _name; } set { _name = value; Raise("Name"); } }
        public string Path { get { return _path; } set { _path = value; Raise("Path"); } }
        public string Status { get { return _status; } set { _status = value; Raise("Status"); } }
        public string StatusKey { get { return _statusKey; } set { _statusKey = value; Raise("StatusKey"); } }
        public string Detail { get { return _detail; } set { _detail = value; Raise("Detail"); } }
        public string Info { get { return _info; } set { _info = value; Raise("Info"); } }
        public string Note { get { return _note; } set { _note = value ?? ""; Raise("Note"); } }
        public double Progress { get { return _progress; } set { _progress = value; Raise("Progress"); } }
    }

    public static class Native
    {
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [StructLayout(LayoutKind.Sequential)] struct MARGINS { public int Left, Right, Top, Bottom; }
        [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS margins);

        public static int SetWindowAttribute(IntPtr hwnd, int attr, int value) { return DwmSetWindowAttribute(hwnd, attr, ref value, 4); }
        public static int ExtendFrameIntoClientArea(IntPtr hwnd) { MARGINS m = new MARGINS(); m.Left = -1; m.Right = -1; m.Top = -1; m.Bottom = -1; return DwmExtendFrameIntoClientArea(hwnd, ref m); }
    }

    // Modern (IFileOpenDialog) folder picker; FolderBrowserDialog on .NET Framework is the old tree view
    public static class FolderPicker
    {
        [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] class FileOpenDialogCo { }

        [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IFileDialog
        {
            [PreserveSig] int Show(IntPtr parent);
            void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
            void SetFileTypeIndex(uint iFileType);
            void GetFileTypeIndex(out uint piFileType);
            void Advise(IntPtr pfde, out uint pdwCookie);
            void Unadvise(uint dwCookie);
            void SetOptions(uint fos);
            void GetOptions(out uint pfos);
            void SetDefaultFolder(IShellItem psi);
            void SetFolder(IShellItem psi);
            void GetFolder(out IShellItem ppsi);
            void GetCurrentSelection(out IShellItem ppsi);
            void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
            void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
            void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
            void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
            void GetResult(out IShellItem ppsi);
        }

        [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IShellItem
        {
            void BindToHandler(IntPtr pbc, [In] ref Guid bhid, [In] ref Guid riid, out IntPtr ppv);
            void GetParent(out IShellItem ppsi);
            void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
            void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
            void Compare(IShellItem psi, uint hint, out int piOrder);
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        static extern void SHCreateItemFromParsingName(string pszPath, IntPtr pbc, [In] ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItem ppv);

        public static string Show(IntPtr owner, string title, string initialFolder)
        {
            IFileDialog dlg = (IFileDialog)new FileOpenDialogCo();
            try
            {
                uint opts;
                dlg.GetOptions(out opts);
                dlg.SetOptions(opts | 0x20 | 0x40);   // FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM
                if (!string.IsNullOrEmpty(title)) dlg.SetTitle(title);
                if (!string.IsNullOrEmpty(initialFolder) && Directory.Exists(initialFolder))
                {
                    try { Guid g = typeof(IShellItem).GUID; IShellItem folder; SHCreateItemFromParsingName(initialFolder, IntPtr.Zero, ref g, out folder); dlg.SetFolder(folder); }
                    catch (Exception) { }
                }
                if (dlg.Show(owner) != 0) return null;
                IShellItem result; dlg.GetResult(out result);
                string path; result.GetDisplayName(0x80058000, out path);   // SIGDN_FILESYSPATH
                return path;
            }
            finally { Marshal.ReleaseComObject(dlg); }
        }
    }

    public class MpvEvent { public int Id; public int Error; public int Reason; public string Text; }

    // Minimal libmpv client: embed via --wid, set options/properties, run commands, poll events
    public class Mpv : IDisposable
    {
        const string Lib = "libmpv-2.dll";
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr LoadLibrary(string path);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr mpv_create();
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int mpv_initialize(IntPtr ctx);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int mpv_set_option_string(IntPtr ctx, byte[] name, byte[] data);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int mpv_set_property_string(IntPtr ctx, byte[] name, byte[] data);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr mpv_get_property_string(IntPtr ctx, byte[] name);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern void mpv_free(IntPtr data);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int mpv_command(IntPtr ctx, IntPtr[] args);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr mpv_wait_event(IntPtr ctx, double timeout);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int mpv_request_log_messages(IntPtr ctx, byte[] minLevel);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr mpv_error_string(int error);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern void mpv_terminate_destroy(IntPtr ctx);

        IntPtr ctx;
        public bool IsAlive { get { return ctx != IntPtr.Zero; } }

        public static bool LoadFrom(string dllPath) { return LoadLibrary(dllPath) != IntPtr.Zero; }

        static byte[] U(string s) { return Encoding.UTF8.GetBytes((s ?? "") + "\0"); }
        static string S(IntPtr p)
        {
            if (p == IntPtr.Zero) return null;
            int n = 0; while (Marshal.ReadByte(p, n) != 0) n++;
            byte[] b = new byte[n]; Marshal.Copy(p, b, 0, n);
            return Encoding.UTF8.GetString(b);
        }

        public Mpv() { ctx = mpv_create(); if (ctx == IntPtr.Zero) throw new InvalidOperationException("mpv_create failed"); }
        public int SetOption(string name, string value) { return mpv_set_option_string(ctx, U(name), U(value)); }
        public int Initialize() { return mpv_initialize(ctx); }
        public int SetProperty(string name, string value) { return IsAlive ? mpv_set_property_string(ctx, U(name), U(value)) : -1; }
        public string GetProperty(string name)
        {
            if (!IsAlive) return null;
            IntPtr p = mpv_get_property_string(ctx, U(name));
            if (p == IntPtr.Zero) return null;
            string s = S(p); mpv_free(p); return s;
        }
        public int RequestLog(string level) { return mpv_request_log_messages(ctx, U(level)); }
        public static string ErrorString(int error) { return S(mpv_error_string(error)); }

        public int Command(params string[] args)
        {
            if (!IsAlive) return -1;
            IntPtr[] arr = new IntPtr[args.Length + 1];
            try
            {
                for (int i = 0; i < args.Length; i++) { byte[] b = U(args[i]); arr[i] = Marshal.AllocHGlobal(b.Length); Marshal.Copy(b, 0, arr[i], b.Length); }
                return mpv_command(ctx, arr);
            }
            finally { foreach (IntPtr p in arr) if (p != IntPtr.Zero) Marshal.FreeHGlobal(p); }
        }

        // Non-blocking; returns null when the queue is empty. 1=shutdown, 2=log message, 7=end-file
        public MpvEvent Poll()
        {
            if (!IsAlive) return null;
            IntPtr ev = mpv_wait_event(ctx, 0);
            int id = Marshal.ReadInt32(ev);
            if (id == 0) return null;
            MpvEvent e = new MpvEvent(); e.Id = id; e.Error = Marshal.ReadInt32(ev, 4);
            IntPtr data = Marshal.ReadIntPtr(ev, 16);
            if (id == 2 && data != IntPtr.Zero)
            {
                string prefix = S(Marshal.ReadIntPtr(data, 0));
                string text = S(Marshal.ReadIntPtr(data, IntPtr.Size * 2));
                e.Text = prefix + ": " + (text ?? "").TrimEnd();
            }
            else if (id == 7 && data != IntPtr.Zero)
            {
                e.Reason = Marshal.ReadInt32(data, 0);
                e.Error = Marshal.ReadInt32(data, 4);
            }
            return e;
        }

        public void Dispose() { if (ctx != IntPtr.Zero) { IntPtr c = ctx; ctx = IntPtr.Zero; mpv_terminate_destroy(c); } }
    }
}
'@

# Per-monitor DPI: WPF only rescales on monitor changes when this switch is off and the process is PMv2-aware
[System.AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false)
if (-not ('IdealVE.Mpv' -as [type])) { Add-Type -TypeDefinition $NativeSource -Language CSharp }
try { if (-not [IdealVE.Native]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [void][IdealVE.Native]::SetProcessDPIAware() } } catch {}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing, WindowsFormsIntegration

# ========== Core helpers (shared by the UI and the background worker) ==========
$CoreScript = {
    function Quote-Arg($s) {
        if ($null -eq $s) { return "" }
        if ($s -match '[\s&();|<>]') { return '"' + ($s -replace '"','\"') + '"' }
        return $s
    }

    # Run a console tool hidden and return its stdout lines (no console window flash in the compiled exe)
    function Invoke-Hidden([string]$exe, [string[]]$argList){
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = ($argList | ForEach-Object { Quote-Arg $_ }) -join ' '
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $null = $p.StandardError.ReadToEndAsync()   # drain stderr so the child can't block on a full pipe
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        $global:LASTEXITCODE = $p.ExitCode
        return ($out -split "\r?\n" | Where-Object { $_ -ne '' })
    }

    # Start a console tool hidden with stderr redirected (ffmpeg progress/log); caller reads and waits
    function Start-Hidden([string]$exe, [string[]]$argList){
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = ($argList | ForEach-Object { Quote-Arg $_ }) -join ' '
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        return [System.Diagnostics.Process]::Start($psi)
    }

    # Escape a Windows path for a lavfi option: C:\a b\x.cube -> 'C\:/a b/x.cube'
    function ConvertTo-FilterPath([string]$path){
        $p = $path -replace '\\','/'
        $p = $p -replace ':','\:'
        $p = $p -replace "'","'\\\''"
        return "'" + $p + "'"
    }

    # Exposure in stops, applied to log footage before the LUT as a luma offset of 0.0738/stop (F-Log2 slope).
    # lutyuv keeps 10-bit precision; eq would force an 8-bit conversion ahead of the LUT.
    function Get-ExposureFilter([double]$ev){
        $k = [math]::Round([math]::Abs($ev) * 0.0738, 4).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $sign = if ($ev -lt 0) { '-' } else { '+' }
        return "lutyuv=y=val$sign$k*(maxval-minval)"
    }

    # Shared filtergraph for encode and preview: exposure -> LUT -> range remap.
    # -Preview downscales first so the 6K sources stay real-time; the per-pixel look is unchanged.
    function Get-FilterChain([double]$Exposure, [string]$LutPath, [bool]$IsFull, [switch]$Preview){
        $vf = @()
        if ($Preview) { $vf += "scale=w=1920:h=1080:force_original_aspect_ratio=decrease:flags=fast_bilinear" }
        $ev = [math]::Round($Exposure, 2)
        if ($ev -ne 0) { $vf += Get-ExposureFilter $ev }
        # gbrp10le is what ffmpeg picks for the encode anyway; pinning it stops mpv feeding the LUT 8-bit rgb24
        if ($LutPath) { $vf += "format=gbrp10le", ("lut3d=file=" + (ConvertTo-FilterPath $LutPath)) }
        # Encode only: mpv.net's libavfilter (FFmpeg 6.1) zscale garbles frames, and mpv already displays
        # full-range sources correctly from their tags, so the preview looks the same without it.
        if ($IsFull -and -not $Preview) { $vf += "zscale=rangein=full:range=limited:matrix=709" }
        return ,$vf
    }

    # x265 tuning per grain-retention level. Off = the standard tuning; Light = SAO and strong-intra-smoothing
    # off (both smear grain), stronger psy-rdoq, softer deblocking; Strong = x265's tune=grain, minus overrides.
    function Get-X265Args([int]$grain){
        switch ($grain) {
            1 { return @("-x265-params", "aq-mode=3:aq-strength=1.0:psy-rd=2:psy-rdoq=4:qg-size=16:sao=0:strong-intra-smoothing=0:deblock=-1,-1:rect=1:amp=1") }
            2 { return @("-tune", "grain", "-x265-params", "qg-size=16:rect=1:amp=1") }
            default { return @("-x265-params", "aq-mode=3:aq-strength=1.2:psy-rd=2:psy-rdoq=1:qg-size=16:sao=1:rect=1:amp=1") }
        }
    }

    # Video encoder arguments for either codec: CRF, optional VBV cap (Mbps), grain level, 10-bit 4:2:0.
    # HEVC: x265 preset slow. AV1: SVT-AV1 with tune=0 (visual quality); grain uses AV1 film-grain synthesis,
    # which re-creates grain at playback instead of spending bits on it.
    function Get-VideoCodecArgs([string]$codec, [int]$crf, [double]$cap, [int]$grain, [int]$width = 0, [int]$height = 0){
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $vbv = @()
        if ($cap -gt 0) { $vbv = @('-maxrate', ($cap.ToString($inv) + 'M'), '-bufsize', (($cap * 2).ToString($inv) + 'M')) }
        if ($codec -eq 'av1') {
            $p = 'tune=0'
            if ($grain -eq 1) { $p += ':film-grain=6:film-grain-denoise=0' }
            elseif ($grain -eq 2) { $p += ':film-grain=12:film-grain-denoise=0' }
            # SVT-AV1 only allows preset 5+ above 4K ('8K class'); preset 4 compresses better where it's allowed
            $preset = if ($width -gt 4096 -or $height -gt 2304) { 5 } else { 4 }
            return @('-c:v', 'libsvtav1', '-preset', "$preset", '-crf', "$crf") + $vbv + @('-svtav1-params', $p, '-pix_fmt', 'yuv420p10le')
        }
        return @('-c:v', 'libx265', '-preset', 'slow', '-crf', "$crf") + $vbv + (Get-X265Args $grain) + @('-pix_fmt', 'yuv420p10le', '-tag:v', 'hvc1')
    }

    # Rough HEVC-CRF -> SVT-AV1-CRF equivalence (similar VMAF), used by Auto CRF and as the AV1 default.
    # Deliberately conservative; the Analysis tab measures the real value for a given clip.
    function ConvertTo-Av1Crf([int]$hevcCrf) { return [int][math]::Max(0, [math]::Min(63, $hevcCrf + 7)) }

    function Get-VideoSize([string]$path){
        $w = 0; $h = 0
        foreach ($l in (Invoke-Hidden 'ffprobe' @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'default=nw=1', $path))) {
            if ($l -match '^width=(\d+)') { $w = [int]$matches[1] } elseif ($l -match '^height=(\d+)') { $h = [int]$matches[1] }
        }
        return @($w, $h)
    }

    function Get-ISO([string]$path){ try{ $isoLine = Invoke-Hidden 'exiftool' @('-ISO', $path) | Select-String "ISO" | ForEach-Object { $_.ToString() }; return ($isoLine -split ":")[1].Trim() -as [int] } catch { return $null } }
    function Is-FLog2([string]$path){ try{ $c = Invoke-Hidden 'exiftool' @('-UserComment', $path); return ($c -match "F-Log2") } catch { return $false } }
    function Get-VideoRangeFull([string]$path){
        try{
            $r = Invoke-Hidden 'ffprobe' @('-v','error','-select_streams','v:0','-show_entries','stream=color_range','-of','default=nk=1:nw=1', $path)
            $txt = ($r | Out-String).ToLower()
            if($txt -match '\b(pc|full)\b'){ return $true }
            if($txt -match '\b(tv|limited)\b'){ return $false }
            return $false  # unknown -> assume limited (safe)
        } catch { return $false }
    }
    function Get-Duration([string]$path){
        try { return (Invoke-Hidden 'ffprobe' @('-v','error','-show_entries','format=duration','-of','default=nk=1:nw=1', $path)) -as [double] } catch { return 0 }
    }
    function Complexity-Score([string]$path){
        try{
            $dur = Get-Duration $path
            $br  = (Invoke-Hidden 'ffprobe' @('-v','error','-select_streams','v:0','-show_entries','stream=bit_rate','-of','default=nk=1:nw=1', $path)) -as [double]
            if($dur -le 0){ return 0 }
            return $br / $dur  # proxy for content complexity
        } catch { return 0 }
    }
    function Heat-Bar([double]$x){
        if($x -le 800000){ return "[1]" }
        elseif($x -le 1600000){ return "[2]" }
        elseif($x -le 2400000){ return "[3]" }
        elseif($x -le 3200000){ return "[4]" }
        elseif($x -le 4800000){ return "[5]" }
        else { return "[6]" }
    }

    # Returns Motion, Colour, BrightMin, BrightMax, DetailVar, NoisePSNR (8-bit scale, half-res decode).
    # metadata=print and the psnr summary log at info level, so -v error would hide every value.
    function Analyze-Clip([string]$path, $Sync){
        $result = @{ Motion = $null; Colour = $null; BrightMin = $null; BrightMax = $null; DetailVar = $null; NoisePSNR = $null }

        # Pass A: signalstats averaged over all frames
        try{
            $p = Start-Hidden 'ffmpeg' @('-v','info','-nostdin','-hide_banner','-i',$path,'-vf','scale=iw/2:ih/2,format=yuv420p,signalstats,metadata=print','-f','null','-')
            if ($Sync) { $Sync.Proc = $p }
            $ydif = 0.0; $nd = 0; $sat = 0.0; $ns = 0
            while ($null -ne ($line = $p.StandardError.ReadLine())) {
                if ($line -match 'signalstats\.YDIF=([\d\.]+)') { $ydif += [double]$matches[1]; $nd++ }
                elseif ($line -match 'signalstats\.SATAVG=([\d\.]+)') { $sat += [double]$matches[1]; $ns++ }
                elseif ($line -match 'signalstats\.YMIN=(\d+)') { $v = [int]$matches[1]; if ($null -eq $result.BrightMin -or $v -lt $result.BrightMin) { $result.BrightMin = $v } }
                elseif ($line -match 'signalstats\.YMAX=(\d+)') { $v = [int]$matches[1]; if ($null -eq $result.BrightMax -or $v -gt $result.BrightMax) { $result.BrightMax = $v } }
            }
            $p.WaitForExit()
            if ($nd) { $result.Motion = $ydif / $nd }
            if ($ns) { $result.Colour = $sat / $ns }
        } catch {}
        if ($Sync -and $Sync.Cancel) { return $result }

        # Pass B: quick noise proxy via denoise-vs-original PSNR
        try{
            $p = Start-Hidden 'ffmpeg' @('-v','info','-nostdin','-hide_banner','-i',$path,'-filter_complex','[0:v]scale=iw/2:ih/2,split=2[a][b];[b]hqdn3d=4:4:6:6[dn];[a][dn]psnr','-f','null','-')
            if ($Sync) { $Sync.Proc = $p }
            while ($null -ne ($line = $p.StandardError.ReadLine())) {
                if ($line -match 'PSNR .*average:([\d\.]+)') { $result.NoisePSNR = [double]$matches[1] }
            }
            $p.WaitForExit()
        } catch {}
        return $result
    }

    # ---- Quality search (shared by the Analysis tab and the "Quality target" encode mode) ----
    function Format-Num([double]$v, [string]$f = '0.0') { $v.ToString($f, [System.Globalization.CultureInfo]::InvariantCulture) }

    # Run ffmpeg hidden and cancellable (registers the process in $Sync.Proc); returns stderr
    function Invoke-FfmpegChecked([string[]]$a, $Sync) {
        $p = Start-Hidden 'ffmpeg' $a
        if ($Sync) { $Sync.Proc = $p }
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if ($Sync) { $Sync.Proc = $null }
        if ($Sync -and $Sync.Cancel) { throw 'cancelled' }
        if ($p.ExitCode -ne 0) { throw ('ffmpeg failed: ' + (($err -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 3) -join ' | ')) }
        return $err
    }

    # Encode every sample segment of $clip at one CRF/cap; return average bitrate, busiest 1 s, VMAF mean and worst 1%
    function Measure-QualityPoint($clip, [int]$crf, [int]$cap, [string]$codec, $Sync, [string]$tmp) {
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $threads = [Environment]::ProcessorCount
        $bits = 0.0; $secs = 0.0; $peak = 0.0
        $scores = New-Object 'System.Collections.Generic.List[double]'
        $i = 0
        foreach ($start in $clip.Starts) {
            $i++
            $out = Join-Path $tmp ("{0}-c{1}-m{2}-s{3}.mp4" -f $clip.Id, $crf, $cap, $i)
            $a = @('-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-ss', (Format-Num $start '0.000'), '-t', (Format-Num $clip.SegLen '0.000'), '-i', $clip.Path)
            if ($clip.Vf.Count) { $a += '-vf', ($clip.Vf -join ',') }
            $a += '-an', '-fps_mode', 'passthrough'
            $a += Get-VideoCodecArgs $codec $crf $cap $clip.Grain $clip.W $clip.H
            $a += '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-color_range', 'tv', $out
            [void](Invoke-FfmpegChecked $a $Sync)

            $pk = @(Invoke-Hidden 'ffprobe' @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=pts_time,size', '-of', 'csv=p=0', $out) |
                ForEach-Object { $t, $s = $_ -split ','; $tv = 0.0; if ([double]::TryParse($t, [System.Globalization.NumberStyles]::Float, $inv, [ref]$tv)) { [pscustomobject]@{ T = $tv; B = [double]$s * 8 } } } |
                Sort-Object T)
            if ($pk.Count -eq 0) { throw 'sample encode produced no video' }
            $frameDur = if ($pk.Count -gt 1) { ($pk[-1].T - $pk[0].T) / ($pk.Count - 1) } else { 1 / 30 }
            $bits += ($pk | Measure-Object B -Sum).Sum
            $secs += ($pk[-1].T - $pk[0].T) + $frameDur
            $j = 0; $acc = 0.0
            for ($k = 0; $k -lt $pk.Count; $k++) {
                $acc += $pk[$k].B
                while ($pk[$k].T - $pk[$j].T -ge 1.0) { $acc -= $pk[$j].B; $j++ }
                if ($pk[$k].T - $pk[0].T + $frameDur -ge 1.0 -or $pk.Count -lt 2) { $peak = [math]::Max($peak, $acc) }
            }
            if ($peak -eq 0) { $peak = $acc }

            $json = Join-Path $tmp ("vmaf-{0}-c{1}-m{2}-s{3}.json" -f $clip.Id, $crf, $cap, $i)
            $jsonEsc = ($json -replace '\\', '/') -replace ':', '\:'
            # Pair frames by index, not timestamp: container timestamp rounding otherwise shifts the pairing by a frame
            $refChain = @($clip.Vf) + @($clip.RefTail) + 'format=yuv420p10le'
            $lavfi = "[0:v]setpts=N/30/TB,format=yuv420p10le[d];[1:v]" + ($refChain -join ',') + ",setpts=N/30/TB" +
                "[r];[d][r]libvmaf=log_fmt=json:log_path='$jsonEsc':n_threads=${threads}:shortest=1"
            [void](Invoke-FfmpegChecked @('-hide_banner', '-nostdin', '-loglevel', 'error', '-i', $out, '-ss', (Format-Num $start '0.000'), '-t', (Format-Num $clip.SegLen '0.000'), '-i', $clip.Path, '-lavfi', $lavfi, '-f', 'null', '-') $Sync)
            $vj = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
            foreach ($f in $vj.frames) { $scores.Add([double]$f.metrics.vmaf) }
            Remove-Item -LiteralPath $out, $json -Force -ErrorAction SilentlyContinue
        }
        $sorted = @($scores | Sort-Object)
        return [pscustomobject]@{
            Crf = $crf; Cap = $cap
            Avg = $bits / $secs / 1e6
            Peak = $peak / 1e6
            Vmaf = ($scores | Measure-Object -Average).Average
            Low = $sorted[[math]::Floor($sorted.Count * 0.01)]
        }
    }

    # Find the highest CRF whose samples meet VMAF $Target with the current look, grain and codec; the cap is set
    # ~20% above the busiest second at that CRF so it only catches spikes. $OnTest is called before each sample
    # encode with (label, percent); $OnPoint after each with (point, label). -Compare also scores $Opt's own CRF/cap.
    function Find-QualityCrf([string]$file, [hashtable]$Opt, [double]$Target, $Sync, [string]$tmp, [int]$Id = 0,
                             [scriptblock]$OnTest, [scriptblock]$OnPoint, [switch]$Compare) {
        $dur = Get-Duration $file
        if (-not ($dur -gt 0)) { throw 'could not read the clip duration' }
        $isFull = [bool](Get-VideoRangeFull $file)
        $probe = Invoke-Hidden 'ffprobe' @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height,bit_rate:format=bit_rate', '-of', 'default=nw=1', $file)
        $info = @{}; foreach ($l in $probe) { $kv = $l -split '=', 2; if (-not $info.ContainsKey($kv[0])) { $info[$kv[0]] = $kv[1] } }

        # Grain: manual level, or the auto rule from ISO / F-Log2 (no noise pass here, to save time)
        $grain = $Opt.Grain
        if ($Opt.AutoGrain) { $iso = Get-ISO $file; $grain = if ((Is-FLog2 $file) -or ($iso -ge 3200)) { 2 } else { 0 } }

        # Samples: one 3 s segment from the middle of short clips, two from longer ones
        $segLen = [math]::Min(3.0, [math]::Max(0.5, $dur - 0.1))
        $starts = if ($dur -le 20) { @([math]::Max(0, ($dur - $segLen) / 2)) } else { @(($dur * 0.3 - $segLen / 2), ($dur * 0.7 - $segLen / 2)) }
        $vf = Get-FilterChain -Exposure $Opt.Exposure -LutPath $Opt.LutPath -IsFull $isFull
        # A LUT leaves RGB; convert the reference the way the encoder does (BT.709, limited)
        $refTail = if ($Opt.LutPath) { @('scale=out_color_matrix=bt709:out_range=tv') } else { @() }
        $clip = @{ Id = $Id; Path = $file; Starts = $starts; SegLen = $segLen; Vf = $vf; RefTail = $refTail; Grain = $grain; W = [int]$info['width']; H = [int]$info['height'] }

        $points = @{}
        $state = @{ Evals = 0; Max = 7 }
        $measure = {
            param([int]$crf, [int]$cap)
            $key = "$crf/$cap"
            if (-not $points.ContainsKey($key)) {
                $state.Evals++
                $label = if ($cap) { "CRF $crf + $cap Mbps cap" } else { "CRF $crf" }
                if ($OnTest) { & $OnTest $label ([math]::Min(95, $state.Evals / $state.Max * 100)) }
                $points[$key] = Measure-QualityPoint $clip $crf $cap $Opt.Codec $Sync $tmp
                if ($OnPoint) { & $OnPoint $points[$key] $label }
            }
            return $points[$key]
        }
        # Dot-sourced, so it updates this function's $good/$bad
        $pick = { $good = @($points.Values | Where-Object { $_.Cap -eq 0 -and $_.Vmaf -ge $Target } | Sort-Object Crf)
                  $bad  = @($points.Values | Where-Object { $_.Cap -eq 0 -and $_.Vmaf -lt $Target } | Sort-Object Crf) }

        # Bracket the target between two measured CRFs, then interpolate (secant). SVT-AV1's CRF runs 0-63, x265's 0-51.
        if ($Opt.Codec -eq 'av1') { $lo = 20; $hi = 55; $p1 = 30; $p2 = 40; $step = 6 } else { $lo = 14; $hi = 34; $p1 = 22; $p2 = 28; $step = 4 }
        [void](& $measure $p1 0)
        [void](& $measure $p2 0)
        $good = @(); $bad = @(); . $pick
        while ($good.Count -eq 0 -and $bad[0].Crf -gt $lo -and $state.Evals -lt $state.Max - 1) {
            [void](& $measure ([math]::Max($lo, $bad[0].Crf - $step)) 0); . $pick
        }
        while ($bad.Count -eq 0 -and $good[-1].Crf -lt $hi -and $state.Evals -lt $state.Max - 1) {
            [void](& $measure ([math]::Min($hi, $good[-1].Crf + $step)) 0); . $pick
        }
        while ($good.Count -and $bad.Count -and ($bad[0].Crf - $good[-1].Crf) -gt 1 -and $state.Evals -lt $state.Max - 1) {
            $g = $good[-1]; $b = $bad[0]
            $guess = $g.Crf + ($g.Vmaf - $Target) * ($b.Crf - $g.Crf) / [math]::Max(0.01, $g.Vmaf - $b.Vmaf)
            $next = [math]::Max($g.Crf + 1, [math]::Min($b.Crf - 1, [int][math]::Round($guess)))
            [void](& $measure $next 0); . $pick
        }
        $met = $good.Count -gt 0
        $best = if ($met) { $good[-1] } else { $points.Values | Where-Object { $_.Cap -eq 0 } | Sort-Object Crf | Select-Object -First 1 }
        $cap = [int]([math]::Ceiling($best.Peak * 1.2 / 5) * 5)

        $current = $null
        if ($Compare -and -not $Opt.AutoCrf -and -not $Opt.QualityTarget) {
            $current = & $measure $Opt.Crf $(if ($Opt.VbrEnabled) { [int][math]::Round($Opt.MaxRate) } else { 0 })
        }
        return [pscustomobject]@{
            Crf = $best.Crf; Cap = $cap; Grain = $grain; Met = $met; Best = $best; Current = $current
            Points = @($points.Values | Where-Object { $_.Cap -eq 0 } | Sort-Object Crf)
            Width = $info['width']; Height = $info['height']; SourceMbps = ([double]($info['bit_rate'] -as [double])) / 1e6
            Samples = $starts.Count; SampleLength = $segLen
        }
    }

    function Resolve-OutputDir([string]$file, [string]$mode, [string]$folder, [string]$sub){
        $base = if ($mode -eq 'custom' -and $folder) { $folder } else { [IO.Path]::GetDirectoryName($file) }
        $sub = "$sub".Trim().Trim('\', '/')
        if ($sub) { return Join-Path $base $sub }
        return $base
    }
}
. $CoreScript

# ========== Background worker (runs in its own runspace; talks to the UI through $Sync.Queue) ==========
$WorkerScript = {
    param($Sync, $Jobs, $Opt, $CoreText)
    . ([scriptblock]::Create($CoreText))
    $inv   = [System.Globalization.CultureInfo]::InvariantCulture
    $dot   = [string][char]0x00B7
    $arrow = [string][char]0x2192

    function Post([hashtable]$m) { $Sync.Queue.Enqueue($m) }
    function Log([string]$text) { Post @{ T = 'log'; Text = $text } }
    function Set-Clip([string]$path, [string]$status, [string]$key, $progress, $detail) {
        $m = @{ T = 'item'; Path = $path; Status = $status; Key = $key }
        if ($null -ne $progress) { $m.Progress = [double]$progress }
        if ($null -ne $detail) { $m.Detail = [string]$detail }
        Post $m
    }
    function Post-Overall([double]$filePct) {
        $frac = [math]::Min(1, ($index + $filePct / 100) / $total)
        $text = "{0} of {1}" -f ([math]::Min($index + 1, $total)), $total
        $eta = ''
        $elapsed = ((Get-Date) - $t0).TotalSeconds
        if ($frac -gt 0.01) { $eta = 'ETA ' + [TimeSpan]::FromSeconds($elapsed * (1 - $frac) / $frac).ToString('hh\:mm\:ss') }
        Post @{ T = 'overall'; Value = $frac * 100; Text = $text; Eta = $eta }
    }

    $total = $Jobs.Count; $index = 0; $ok = 0; $failed = 0; $qTmp = $null
    $t0 = Get-Date
    $usedOut = @{}

    if ($Opt.CsvEnabled -and -not (Test-Path -LiteralPath $Opt.CsvPath)) {
        try { "File,ISO,FLog2,CRF,Grain,OrigBitrate(bps),OrigSize(MB),NewSize(MB),Compression(%),Heat,Notes" | Out-File -Encoding UTF8 -LiteralPath $Opt.CsvPath }
        catch { Log "Could not create CSV log: $($_.Exception.Message)" }
    }

    foreach ($file in $Jobs) {
        if ($Sync.Cancel) { break }
        $nameOnly = [IO.Path]::GetFileName($file)
        $base     = [IO.Path]::GetFileNameWithoutExtension($file)
        $outPath  = $null
        try {
            if (-not (Test-Path -LiteralPath $file)) { throw "source file not found" }
            $outDir = Resolve-OutputDir $file $Opt.OutputMode $Opt.OutputFolder $Opt.Subfolder
            if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

            # Never overwrite the source itself, or an earlier output from this run (same names from two cards)
            $ext = $Opt.Ext
            $n = 1
            $outPath = Join-Path $outDir "$base$ext"
            while ($outPath -ieq $file -or $usedOut.ContainsKey($outPath.ToLowerInvariant())) { $n++; $outPath = Join-Path $outDir ("{0}_{1}{2}" -f $base, $n, $ext) }
            $usedOut[$outPath.ToLowerInvariant()] = $true

            Set-Clip $file 'Analyzing' 'active' 0 $null
            Post-Overall 0

            # Source analysis
            $iso     = Get-ISO $file
            $isFlog2 = [bool](Is-FLog2 $file)
            $isFull  = [bool](Get-VideoRangeFull $file)
            $heat    = Heat-Bar (Complexity-Score $file)
            Log ("{0}: ISO {1}, F-Log2 {2}, source range {3}" -f $nameOnly, $(if ($iso) { $iso } else { 'n/a' }), $(if ($isFlog2) { 'yes' } else { 'no' }), $(if ($isFull) { 'full -> zscale to limited' } else { 'limited' }))

            # CRF/cap/grain for this clip, in priority order:
            #   1. Quality target: a per-clip analysis for the same target and settings, otherwise measure now
            #   2. A per-clip analysis applied from the Analysis tab ("Use per clip") for the same settings
            #   3. The global CRF (manual or Auto) and cap
            $q = $null; $qSource = ''
            $ov = if ($Opt.Overrides) { $Opt.Overrides[$file] } else { $null }
            if ($ov -and $ov.Key -ne $Opt.LookKey) {
                Log "${nameOnly}: its analysis was made with different codec/look/grain settings, so it isn't used."
                $ov = $null
            }
            if ($Opt.QualityTarget -gt 0) {
                if ($ov -and [double]$ov.Target -eq [double]$Opt.QualityTarget) {
                    $q = $ov; $qSource = "analysed, VMAF $($Opt.QualityTarget)"
                    Log "${nameOnly}: reusing its analysis for VMAF $($Opt.QualityTarget): CRF $($q.Crf), cap $($q.Cap) Mbps."
                } else {
                    if (-not $qTmp) { $qTmp = Join-Path ([IO.Path]::GetTempPath()) ('IdealVE-target-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $qTmp -Force | Out-Null }
                    $onTest = { param($label, $pct) Set-Clip $file "Measuring ($label)" 'active' $pct "Finding the CRF for VMAF $($Opt.QualityTarget)"; Post-Overall 0 }
                    $onPoint = { param($pt, $label) Log ("{0}: {1} {2} {3} Mbps, VMAF {4}" -f $nameOnly, $label, $arrow, (Format-Num $pt.Avg), (Format-Num $pt.Vmaf '0.00')) }
                    $r = Find-QualityCrf $file $Opt ([double]$Opt.QualityTarget) $Sync $qTmp $index $onTest $onPoint
                    $q = @{ Crf = $r.Crf; Cap = $r.Cap; Grain = $r.Grain; Target = $Opt.QualityTarget; Key = $Opt.LookKey; Met = $r.Met; Vmaf = $r.Best.Vmaf }
                    $qSource = "VMAF $($Opt.QualityTarget)"
                    Log ("{0}: VMAF {1} target {2} CRF {3}, cap {4} Mbps (sample VMAF {5}){6}" -f $nameOnly, $Opt.QualityTarget, $arrow, $r.Crf, $r.Cap, (Format-Num $r.Best.Vmaf), $(if (-not $r.Met) { '; target not reached, using the best tested' } else { '' }))
                    # Remember it on the clip, so re-running with the same settings skips the measurement
                    Post @{ T = 'override'; Path = $file; Crf = $r.Crf; Cap = $r.Cap; Grain = $r.Grain; Target = $Opt.QualityTarget; Key = $Opt.LookKey; Met = $r.Met; CodecName = $Opt.CodecName; Vmaf = $r.Best.Vmaf }
                }
            } elseif ($ov) {
                $q = $ov; $qSource = 'analysed'
                Log "${nameOnly}: using its analysis: CRF $($q.Crf), cap $($q.Cap) Mbps."
            }

            $motion = $null; $detail = $null; $psnr = $null
            if (-not $q -and ($Opt.AutoCrf -or $Opt.AutoGrain)) {
                $analysis = Analyze-Clip $file $Sync
                $Sync.Proc = $null
                if ($Sync.Cancel) { Set-Clip $file 'Cancelled' 'cancelled' 0 $null; break }
                $motion = $analysis.Motion; $detail = $analysis.DetailVar; $psnr = $analysis.NoisePSNR
                Log ("{0}: analysis Motion(YDIF)={1} Colour(SATAVG)={2} Bright={3}-{4} NoisePSNR={5} dB" -f $nameOnly,
                    $(if ($null -ne $motion) { [math]::Round($motion, 1) } else { 'n/a' }),
                    $(if ($null -ne $analysis.Colour) { [math]::Round($analysis.Colour, 1) } else { 'n/a' }),
                    $(if ($null -ne $analysis.BrightMin) { $analysis.BrightMin } else { 'n/a' }),
                    $(if ($null -ne $analysis.BrightMax) { $analysis.BrightMax } else { 'n/a' }),
                    $(if ($psnr) { [math]::Round($psnr, 1) } else { 'n/a' }))
            }

            if ($q) {
                # The measured CRF only holds for the grain level it was measured with
                $crf = [int]$q.Crf; $grain = [int]$q.Grain
                $capUse = if ($Opt.VbrEnabled) { [double]$q.Cap } else { 0 }
            } else {
                # Grain selection (baseline from ISO/log + noise)
                $grain = $Opt.Grain
                if ($Opt.AutoGrain) {
                    $grain = 0
                    if ($isFlog2 -or ($iso -ge 3200)) { $grain = 2 }
                    if ($psnr -and $psnr -lt 35)     { $grain = [math]::Max($grain, 2) }  # very noisy
                    elseif ($psnr -and $psnr -lt 38) { $grain = [math]::Max($grain, 1) }  # somewhat noisy
                }

                # CRF selection (noise/motion/detail plus ISO/log signals)
                $crf = $Opt.Crf
                if ($Opt.AutoCrf) {
                    $crf = 22
                    if ($psnr) {
                        if ($psnr -lt 35) { $crf -= 3 }
                        elseif ($psnr -lt 38) { $crf -= 2 }
                        elseif ($psnr -lt 40) { $crf -= 1 }
                    } elseif ($isFlog2 -or ($iso -ge 3200)) {
                        $crf -= 2
                    }
                    if ($motion -and $motion -gt 50) { $crf -= 1 }
                    if ($detail -and $detail -gt 8000) { $crf -= 1 }
                    if ($motion -and $motion -lt 10 -and $detail -and $detail -lt 3000) { $crf += 1 }
                    if ($crf -lt 16) { $crf = 16 }
                    if ($crf -gt 24) { $crf = 24 }
                    if ($Opt.Codec -eq 'av1') { $crf = ConvertTo-Av1Crf $crf }
                }
                $capUse = if ($Opt.VbrEnabled) { [double]$Opt.MaxRate } else { 0 }
            }

            $crfText   = if ($q) { "$crf ($qSource)" } elseif ($Opt.AutoCrf) { "$crf (auto)" } else { "$crf" }
            $grainText = @('Off', 'Light', 'Strong')[$grain]
            if ($Opt.AutoGrain) { $grainText += ' (auto)' }
            $vbvText   = if ($capUse -gt 0) { $capUse.ToString($inv) + "M" } else { 'off' }
            $evText    = $Opt.Exposure.ToString('+0.0;-0.0;0.0', $inv)
            $detailBase = "$($Opt.CodecName) CRF $crfText $dot Grain $grainText"
            if ($capUse -gt 0) { $detailBase += " $dot cap $($capUse.ToString($inv)) Mbps" }
            if ($Opt.Exposure -ne 0) { $detailBase += " $dot $evText EV" }

            # Build args
            $ffArgs = @("-y", "-nostdin", "-hide_banner")
            if ($null -ne $Opt.TrimStart) { $ffArgs += "-ss", $Opt.TrimStart.ToString($inv) }
            if ($null -ne $Opt.TrimEnd)   { $ffArgs += "-to", $Opt.TrimEnd.ToString($inv) }
            $ffArgs += "-i", $file

            $vf = Get-FilterChain -Exposure $Opt.Exposure -LutPath $Opt.LutPath -IsFull $isFull
            if ($vf.Count -gt 0) {
                $ffArgs += "-vf", ($vf -join ",")
                Log "${nameOnly}: filters $($vf -join ',')"
            }

            # Remove an existing output so ffmpeg/ExifTool start clean
            if (Test-Path -LiteralPath $outPath) {
                try { Remove-Item -LiteralPath $outPath -Force; Log "Removed existing file: $outPath" }
                catch { Log "WARNING: Could not remove existing file: $outPath" }
            }

            $pixfmt = Invoke-Hidden 'ffprobe' @('-v','error','-select_streams','v:0','-show_entries','stream=pix_fmt','-of','default=nw=1:nk=1', $file)
            Log "${nameOnly}: pixel format $pixfmt"

            # Constrained VBR when capped: CRF quality target, VBV caps peaks (buffer = 2x max rate)
            $size = Get-VideoSize $file
            $ffArgs += Get-VideoCodecArgs $Opt.Codec $crf $capUse $grain $size[0] $size[1]
            $ffArgs += "-c:a","aac","-b:a","320k","-ar","48000","-ac","2"
            $ffArgs += "-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709","-color_range","tv","-movflags","+faststart"
            $ffArgs += $outPath

            # Target duration for progress
            $srcDur = Get-Duration $file
            $targetDuration = $srcDur
            if ($null -ne $Opt.TrimStart -and $null -ne $Opt.TrimEnd) { $targetDuration = $Opt.TrimEnd - $Opt.TrimStart }
            elseif ($null -ne $Opt.TrimEnd)   { $targetDuration = $Opt.TrimEnd }
            elseif ($null -ne $Opt.TrimStart) { $targetDuration = $srcDur - $Opt.TrimStart }

            Set-Clip $file 'Encoding 0%' 'active' 0 $detailBase
            $proc = Start-Hidden 'ffmpeg' $ffArgs
            $Sync.Proc = $proc
            try { $proc.PriorityClass = 'BelowNormal' } catch {}   # keep the UI and preview smooth
            $tail = New-Object 'System.Collections.Generic.Queue[string]'
            while ($null -ne ($line = $proc.StandardError.ReadLine())) {
                $tail.Enqueue($line); if ($tail.Count -gt 12) { [void]$tail.Dequeue() }
                if ($line -match "time=(\d+):(\d+):(\d+\.?\d*)") {
                    $cur = ([int]$matches[1] * 3600) + ([int]$matches[2] * 60) + [double]$matches[3]
                    if ($targetDuration -gt 0) {
                        $pct = [math]::Min(100, ($cur / $targetDuration) * 100)
                        $speed = if ($line -match 'speed=\s*([\d\.]+)x') { " $dot " + $matches[1] + "x" } else { '' }
                        Set-Clip $file ("Encoding {0:0}%" -f $pct) 'active' $pct ($detailBase + $speed)
                        Post-Overall $pct
                    }
                }
            }
            $proc.WaitForExit()
            $Sync.Proc = $null

            if ($Sync.Cancel) {
                Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
                Set-Clip $file 'Cancelled' 'cancelled' 0 $detailBase
                Log "${nameOnly}: cancelled, partial output removed."
                break
            }
            if ($proc.ExitCode -ne 0) {
                Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
                throw ("ffmpeg exited with code {0}`r`n    {1}" -f $proc.ExitCode, ($tail.ToArray() -join "`r`n    "))
            }

            # --- Metadata ---
            Set-Clip $file 'Metadata' 'active' 100 $detailBase
            $timeSource = Invoke-Hidden 'exiftool' @('-s','-G1','-api','QuickTimeUTC=1',
                '-UserData:DateTimeOriginal',
                '-EXIF:DateTimeOriginal',
                '-XMP:DateTimeOriginal',
                $file)
            $chosen = $null
            foreach ($tl in $timeSource) {
                if ($tl -match 'DateTimeOriginal\s*:\s*(.+)$') {
                    $val = $matches[1].Trim()
                    if ($val -and -not $chosen) { $chosen = $val; Log "${nameOnly}: timestamp source $tl" }
                }
            }
            if (-not $chosen) { Log "${nameOnly}: WARNING no DateTimeOriginal found." }

            # Pass 1: Copy core metadata and file timestamps
            $exifArgs1 = @(
                "-api","QuickTimeUTC=1",
                "-TagsFromFile",$file,
                "-All", "-makernotes", "-make", "-model",

                # Core Make/Model
                "-Keys:Make<Make",
                "-Keys:Model<Model",
                "-QuickTime:Make<Make",
                "-QuickTime:Model<Model",

                # Standard Lens Data Mapping
                "-LensModel<LensModel",
                "-LensModel<LensInfo",         # Fallback for Fujifilm
                "-LensModel<Lens",             # Fallback for Canon
                "-FocalLength<FocalLength",
                "-FocalLengthIn35mmFormat<FocalLengthIn35mmFormat",

                # Apple VideoKeys / iOS Mapping (crucial for Apple Photos / iPhone)
                "-VideoKeys:LensModel-eng-GB<LensInfo",
                "-VideoKeys:FocalLengthIn35mmFormat-eng-GB<FocalLengthIn35mmFormat",
                "-VideoKeys:LensModel<LensModel",
                "-VideoKeys:LensModel<LensInfo",
                "-VideoKeys:FocalLengthIn35mmFormat<FocalLengthIn35mmFormat",
                "-VideoKeys:CameraFocalLength35mmEquivalent<FocalLengthIn35mmFormat",

                # Fuji Film Simulations & Color
                "-Keys:FilmSimulation<FilmMode",
                "-Keys:DynamicRange<DynamicRangeSetting",
                "-Keys:WhiteBalance<WhiteBalance",
                "-Keys:HighlightTone<HighlightTone",
                "-Keys:ShadowTone<ShadowTone",

                # Focus & Hardware Status
                "-Keys:FocusMode<FocusMode",
                "-Keys:ImageStabilization<ImageStabilization",
                "-Keys:CameraSerialNumber<InternalSerialNumber",
                "-Keys:LensSerialNumber<LensSerialNumber",

                # Extended GPS Data
                "-GPSAltitude<GPSAltitude",
                "-GPSAltitudeRef<GPSAltitudeRef",
                "-GPSSpeed<GPSSpeed",
                "-GPSSpeedRef<GPSSpeedRef",

                # Time and Location Data
                "-Keys:GPSCoordinates<Composite:GPSPosition",
                "-Keys:CreationDate<XMP:DateTimeOriginal",
                "-Keys:CreationDate<EXIF:DateTimeOriginal",
                "-QuickTime:CreateDate<DateTimeOriginal",
                "-QuickTime:ModifyDate<DateTimeOriginal",

                "-overwrite_original"
            )
            $null = Invoke-Hidden 'exiftool' ($exifArgs1 + $outPath)
            if ($LASTEXITCODE -ne 0) { Log "${nameOnly}: ExifTool pass 1 failed. Skipping advanced metadata." }
            else { Log "${nameOnly}: core metadata copied." }

            <# Pass 2: Copy XMP Subject metadata conditionally and with proper formatting
            try {
                $metaData = & exiftool -json -n -FNumber -ISO -ShutterSpeed -ExposureTime "$file" | Out-String | ConvertFrom-Json
                $fNumber      = $metaData[0].FNumber
                $iso          = $metaData[0].ISO
                $exposureTime = $metaData[0].ExposureTime
                $shutterSpeed = "1/$([math]::Round(1 / [double]$exposureTime))"
            }
            catch { $fNumber = $null; $iso = $null; $shutterSpeed = $null }

            if ($fNumber -and $iso -and $shutterSpeed) {
                & exiftool -overwrite_original "-XMP:Subject=" "$outPath"
                if ($LASTEXITCODE -eq 0) {
                    $exifArgs2 = @(
                        "-api", "QuickTimeUTC=1",
                        "-XMP:Subject+=f/$fNumber",
                        "-XMP:Subject+=ISO$iso",
                        "-XMP:Subject+=$shutterSpeed`s",
                        "-ItemList:Keywords+=f/${FNumber}",
                        "-ItemList:Keywords+=ISO${ISO}",
                        "-ItemList:Keywords+=1/${ShutterSpeed}s",
                        "-overwrite_original"
                    )
                    & exiftool @exifArgs2 "`"$outPath`""
                }
            }#>

            # Filesystem timestamps from the capture time
            if ($chosen) {
                $null = Invoke-Hidden 'exiftool' @("-FileCreateDate=$chosen", "-FileModifyDate=$chosen", '-overwrite_original', $outPath)
                if ($LASTEXITCODE -eq 0) { Log "${nameOnly}: FileCreateDate/ModifyDate set from $chosen" }
                else { Log "${nameOnly}: WARNING failed to set file system dates" }
            }

            # Sizes + log
            $origSizeMB  = ((Get-Item -LiteralPath $file).Length / 1MB)
            $newSizeMB   = ((Get-Item -LiteralPath $outPath).Length / 1MB)
            $origBitrate = (Invoke-Hidden 'ffprobe' @('-v','error','-select_streams','v:0','-show_entries','stream=bit_rate','-of','default=nk=1:nw=1', $file)) -as [double]
            $ratio = 0; if ($origSizeMB -gt 0) { $ratio = [math]::Round((1 - ($newSizeMB / $origSizeMB)) * 100, 1) }
            $rangeStr = if ($isFull) { 'full' } else { 'video' }
            $notes = "Codec=$($Opt.CodecName) ISO=$iso FLog2=$isFlog2 Range=$rangeStr EV=$evText VBV=$vbvText"
            Log ("{0} -> {1} | saved {2}% ({3} -> {4} MB) | CRF={5} Grain={6} VBV={7} EV={8} | Heat {9}" -f $nameOnly, $outPath, $ratio, [math]::Round($origSizeMB, 1), [math]::Round($newSizeMB, 1), $crf, $grain, $vbvText, $evText, $heat)
            if ($Opt.CsvEnabled) {
                try { Add-Content -Encoding UTF8 -LiteralPath $Opt.CsvPath ("`"$nameOnly`",$iso,$isFlog2,$crf,$grain,$origBitrate,$([math]::Round($origSizeMB,2)),$([math]::Round($newSizeMB,2)),$ratio,$heat,`"$notes`"") }
                catch { Log "Could not write CSV log: $($_.Exception.Message)" }
            }

            $sizeText = "{0:0.#} MB {1} {2:0.#} MB" -f $origSizeMB, $arrow, $newSizeMB
            Set-Clip $file ("Done {0}{1}%" -f $(if ($ratio -ge 0) { '-' } else { '+' }), [math]::Abs($ratio)) 'done' 100 "$sizeText $dot $detailBase"
            $ok++
        }
        catch {
            $Sync.Proc = $null
            if ($Sync.Cancel) { Set-Clip $file 'Cancelled' 'cancelled' 0 $null; Log "${nameOnly}: cancelled."; break }
            Set-Clip $file 'Failed' 'error' 0 $null
            Log "${nameOnly}: FAILED - $($_.Exception.Message)"
            $failed++
        }
        $index++
        Post-Overall 0
    }

    if ($qTmp) { Remove-Item -LiteralPath $qTmp -Recurse -Force -ErrorAction SilentlyContinue }
    Post @{ T = 'end'; Ok = $ok; Failed = $failed; Cancelled = [bool]$Sync.Cancel; Elapsed = ((Get-Date) - $t0) }
}

# ========== Analysis worker: sample encodes + VMAF to suggest CRF and bitrate cap per clip ==========
# Each clip is analysed on its own (Find-QualityCrf). Results are reported per clip ('aresult') so the UI can keep
# them per clip, plus an overall suggestion (the most demanding clip's CRF and the largest cap) for "Apply to all".
$AnalyzeScript = {
    param($Sync, $Jobs, $Opt, $CoreText)
    . ([scriptblock]::Create($CoreText))
    $dot = [string][char]0x00B7
    $arrow = [string][char]0x2192
    $T = [double]$Opt.TargetVmaf

    function Post([hashtable]$m) { $Sync.Queue.Enqueue($m) }
    function Log([string]$text) { Post @{ T = 'log'; Text = $text } }
    function Set-Ana([string]$path, [string]$status, [string]$key, $progress, $detail) {
        $m = @{ T = 'aitem'; Path = $path; Status = $status; Key = $key }
        if ($null -ne $progress) { $m.Progress = [double]$progress }
        if ($null -ne $detail) { $m.Detail = [string]$detail }
        Post $m
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('IdealVE-analysis-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $total = $Jobs.Count; $index = 0; $t0 = Get-Date
    $results = @()

    try {
        foreach ($file in $Jobs) {
            if ($Sync.Cancel) { break }
            $name = [IO.Path]::GetFileName($file)
            try {
                Set-Ana $file 'Preparing' 'active' 0 'Reading clip...'
                $onTest = {
                    param($label, $pct)
                    Set-Ana $file "Testing $label" 'active' $pct "$($Opt.CodecName) $dot target VMAF $T"
                    $frac = ($index + $pct / 100) / $total
                    $el = ((Get-Date) - $t0).TotalSeconds
                    Post @{ T = 'overall'; Value = $frac * 100; Text = ("Analysing {0} of {1}" -f ($index + 1), $total); Eta = $(if ($frac -gt 0.02) { 'ETA ' + [TimeSpan]::FromSeconds($el * (1 - $frac) / $frac).ToString('hh\:mm\:ss') } else { '' }) }
                }
                $onPoint = {
                    param($pt, $label)
                    Log ("{0}: {1} {2} {3} Mbps avg, {4} Mbps peak, VMAF {5} (worst 1% {6})" -f $name, $label, $arrow, (Format-Num $pt.Avg), (Format-Num $pt.Peak), (Format-Num $pt.Vmaf '0.00'), (Format-Num $pt.Low))
                }
                $r = Find-QualityCrf $file $Opt $T $Sync $tmp $index $onTest $onPoint -Compare
                $best = $r.Best

                $lines = @()
                $lines += "{5} $dot {0}x{1} $dot source {2} Mbps $dot {3} sample(s) of {4} s" -f $r.Width, $r.Height, (Format-Num $r.SourceMbps '0'), $r.Samples, (Format-Num $r.SampleLength '0.#'), $Opt.CodecName
                $lines += ("Suggested: CRF {0} + {1} Mbps cap {2} ~{3} Mbps avg (~{4} GB per hour), VMAF {5}, worst 1% {6}" -f $r.Crf, $r.Cap, $arrow, (Format-Num $best.Avg '0'), (Format-Num ($best.Avg * 0.45) '0'), (Format-Num $best.Vmaf), (Format-Num $best.Low))
                if (-not $r.Met) { $lines += ("Even CRF {0} stayed below VMAF {1}; this is the best tested." -f $r.Crf, (Format-Num $T '0')) }
                if ($r.Current) {
                    $c = $r.Current
                    $curLabel = if ($c.Cap) { "CRF $($c.Crf) + $($c.Cap) Mbps cap" } else { "CRF $($c.Crf), no cap" }
                    $lines += ("Your current {0} {1} {2} Mbps, VMAF {3}, worst 1% {4}" -f $curLabel, $arrow, (Format-Num $c.Avg '0'), (Format-Num $c.Vmaf), (Format-Num $c.Low))
                }
                $lines += "Tested: " + (($r.Points | ForEach-Object { "CRF {0}: {1} Mbps / VMAF {2}" -f $_.Crf, (Format-Num $_.Avg '0'), (Format-Num $_.Vmaf) }) -join "  $dot  ")

                Set-Ana $file ("CRF {0} $dot {1} Mbps cap" -f $r.Crf, $r.Cap) $(if ($r.Met) { 'done' } else { 'error' }) 100 ($lines -join "`n")
                Post @{ T = 'aresult'; Path = $file; Crf = $r.Crf; Cap = $r.Cap; Grain = $r.Grain; Met = $r.Met; Target = $T; Key = $Opt.LookKey; CodecName = $Opt.CodecName; Vmaf = $best.Vmaf }
                $results += [pscustomobject]@{ Name = $name; Crf = $r.Crf; Cap = $r.Cap; Met = $r.Met }
            }
            catch {
                if ($Sync.Cancel) { Set-Ana $file 'Cancelled' 'cancelled' 0 $null; break }
                Set-Ana $file 'Failed' 'error' 0 ("Analysis failed: " + $_.Exception.Message)
                Log "${name}: analysis failed - $($_.Exception.Message)"
            }
            $index++
        }
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    # Overall: the most demanding clip's CRF and the largest cap, so every analysed clip meets the target
    $m = @{ T = 'aend'; Cancelled = [bool]$Sync.Cancel; Count = $results.Count; Elapsed = ((Get-Date) - $t0) }
    if ($results.Count) {
        $m.Crf = ($results | Measure-Object Crf -Minimum).Minimum
        $m.Cap = ($results | Measure-Object Cap -Maximum).Maximum
    }
    Post $m
}
# ========== Theme (follows Windows light/dark mode and accent colour) ==========
$IsLight = $true
try { $IsLight = [int](Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme') -ne 0 } catch {}

function Get-AccentHex([int]$index, [string]$fallback) {
    try {
        $p = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -ErrorAction Stop).AccentPalette
        if ($p -and $p.Length -ge 32) { return ('{0:X2}{1:X2}{2:X2}' -f $p[$index * 4], $p[$index * 4 + 1], $p[$index * 4 + 2]) }
    } catch {}
    return $fallback
}

if ($IsLight) {
    $acc = Get-AccentHex 4 '005FB8'   # AccentDark1, what Windows uses for buttons in light mode
    $Palette = @{
        WindowBg = '#FFF3F3F3'; CardBg = '#B3FFFFFF'; CardStroke = '#12000000'
        Text = '#E4000000'; Text2 = '#9E000000'; Text3 = '#72000000'
        ControlBg = '#B3FFFFFF'; ControlHover = '#80F9F9F9'; ControlPressed = '#4DF9F9F9'; ControlStroke = '#24000000'
        InputBg = '#B3FFFFFF'; InputHover = '#80F9F9F9'; InputFocus = '#FFFFFFFF'
        Subtle = '#0A000000'; SubtlePressed = '#06000000'; Track = '#29000000'
        ToggleStroke = '#72000000'; ToggleKnob = '#72000000'; ThumbBg = '#FFFFFFFF'
        Flyout = '#FFF9F9F9'; FlyoutStroke = '#1F000000'; Divider = '#12000000'; FocusStroke = '#E4000000'
        Success = '#FF0F7B0F'; SuccessBg = '#1F0F7B0F'; Danger = '#FFC42B1C'; DangerBg = '#1FC42B1C'
        AccentText = '#FFFFFFFF'
    }
} else {
    $acc = Get-AccentHex 1 '60CDFF'   # AccentLight2, what Windows uses for buttons in dark mode
    $Palette = @{
        WindowBg = '#FF202020'; CardBg = '#0DFFFFFF'; CardStroke = '#33000000'
        Text = '#FFFFFFFF'; Text2 = '#C5FFFFFF'; Text3 = '#87FFFFFF'
        ControlBg = '#0FFFFFFF'; ControlHover = '#15FFFFFF'; ControlPressed = '#08FFFFFF'; ControlStroke = '#17FFFFFF'
        InputBg = '#0FFFFFFF'; InputHover = '#15FFFFFF'; InputFocus = '#B31E1E1E'
        Subtle = '#0FFFFFFF'; SubtlePressed = '#0AFFFFFF'; Track = '#3DFFFFFF'
        ToggleStroke = '#9AFFFFFF'; ToggleKnob = '#CDFFFFFF'; ThumbBg = '#FF454545'
        Flyout = '#FF2C2C2C'; FlyoutStroke = '#66000000'; Divider = '#15FFFFFF'; FocusStroke = '#FFFFFFFF'
        Success = '#FF6CCB5F'; SuccessBg = '#296CCB5F'; Danger = '#FFFF99A4'; DangerBg = '#29FF99A4'
        AccentText = '#FF000000'
    }
}
$Palette.Accent = "#FF$acc"; $Palette.AccentHover = "#E6$acc"; $Palette.AccentPressed = "#CC$acc"; $Palette.AccentBg = "#24$acc"

# ========== XAML ==========
$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Ideal Video Encoder" Width="1280" Height="820" MinWidth="1000" MinHeight="640"
        WindowStartupLocation="CenterScreen" AllowDrop="True"
        Background="{DynamicResource WindowBg}" Foreground="{DynamicResource Text}"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="WindowBg" Color="@WindowBg@"/>
    <SolidColorBrush x:Key="CardBg" Color="@CardBg@"/>
    <SolidColorBrush x:Key="CardStroke" Color="@CardStroke@"/>
    <SolidColorBrush x:Key="Text" Color="@Text@"/>
    <SolidColorBrush x:Key="Text2" Color="@Text2@"/>
    <SolidColorBrush x:Key="Text3" Color="@Text3@"/>
    <SolidColorBrush x:Key="ControlBg" Color="@ControlBg@"/>
    <SolidColorBrush x:Key="ControlHover" Color="@ControlHover@"/>
    <SolidColorBrush x:Key="ControlPressed" Color="@ControlPressed@"/>
    <SolidColorBrush x:Key="ControlStroke" Color="@ControlStroke@"/>
    <SolidColorBrush x:Key="InputBg" Color="@InputBg@"/>
    <SolidColorBrush x:Key="InputHover" Color="@InputHover@"/>
    <SolidColorBrush x:Key="InputFocus" Color="@InputFocus@"/>
    <SolidColorBrush x:Key="Subtle" Color="@Subtle@"/>
    <SolidColorBrush x:Key="SubtlePressed" Color="@SubtlePressed@"/>
    <SolidColorBrush x:Key="Track" Color="@Track@"/>
    <SolidColorBrush x:Key="ToggleStroke" Color="@ToggleStroke@"/>
    <SolidColorBrush x:Key="ToggleKnob" Color="@ToggleKnob@"/>
    <SolidColorBrush x:Key="ThumbBg" Color="@ThumbBg@"/>
    <SolidColorBrush x:Key="Flyout" Color="@Flyout@"/>
    <SolidColorBrush x:Key="FlyoutStroke" Color="@FlyoutStroke@"/>
    <SolidColorBrush x:Key="Divider" Color="@Divider@"/>
    <SolidColorBrush x:Key="FocusStroke" Color="@FocusStroke@"/>
    <SolidColorBrush x:Key="Success" Color="@Success@"/>
    <SolidColorBrush x:Key="SuccessBg" Color="@SuccessBg@"/>
    <SolidColorBrush x:Key="Danger" Color="@Danger@"/>
    <SolidColorBrush x:Key="DangerBg" Color="@DangerBg@"/>
    <SolidColorBrush x:Key="Accent" Color="@Accent@"/>
    <SolidColorBrush x:Key="AccentHover" Color="@AccentHover@"/>
    <SolidColorBrush x:Key="AccentPressed" Color="@AccentPressed@"/>
    <SolidColorBrush x:Key="AccentBg" Color="@AccentBg@"/>
    <SolidColorBrush x:Key="AccentText" Color="@AccentText@"/>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>

    <DrawingImage x:Key="AppIcon">
      <DrawingImage.Drawing>
        <DrawingGroup>
          <GeometryDrawing Brush="{StaticResource Accent}">
            <GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,32,32" RadiusX="7" RadiusY="7"/></GeometryDrawing.Geometry>
          </GeometryDrawing>
          <GeometryDrawing Brush="{StaticResource AccentText}" Geometry="M12.5,9.5 L23,16 L12.5,22.5 Z"/>
        </DrawingGroup>
      </DrawingImage.Drawing>
    </DrawingImage>

    <Style x:Key="FocusRing">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate>
            <Border Margin="-3" CornerRadius="7" BorderThickness="2" BorderBrush="{StaticResource FocusStroke}"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource CardBg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardStroke}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="Caption" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{StaticResource Text2}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="DividerLine" TargetType="Rectangle">
      <Setter Property="Height" Value="1"/>
      <Setter Property="Fill" Value="{StaticResource Divider}"/>
      <Setter Property="Margin" Value="0,14"/>
    </Style>

    <!-- Buttons -->
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Background" Value="{StaticResource ControlBg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlStroke}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{StaticResource ControlHover}"/></Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter Property="Background" Value="{StaticResource ControlPressed}"/>
          <Setter Property="Foreground" Value="{StaticResource Text2}"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Foreground" Value="{StaticResource AccentText}"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{StaticResource AccentHover}"/></Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter Property="Background" Value="{StaticResource AccentPressed}"/>
          <Setter Property="Foreground" Value="{StaticResource AccentText}"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="SubtleButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Padding" Value="8,0"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{StaticResource Subtle}"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="{StaticResource SubtlePressed}"/></Trigger>
      </Style.Triggers>
    </Style>

    <!-- Toggle switch (CheckBox) -->
    <Style x:Key="Toggle" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <ContentPresenter VerticalAlignment="Center" Margin="0,0,12,0" RecognizesAccessKey="True"/>
              <Border x:Name="track" Grid.Column="1" Width="40" Height="20" CornerRadius="10" BorderThickness="1"
                      Background="{StaticResource ControlBg}" BorderBrush="{StaticResource ToggleStroke}" VerticalAlignment="Center">
                <Ellipse x:Name="knob" Width="12" Height="12" Margin="4,0" HorizontalAlignment="Left" Fill="{StaticResource ToggleKnob}"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="knob" Property="Width" Value="14"/>
                <Setter TargetName="knob" Property="Height" Value="14"/>
                <Setter TargetName="knob" Property="Margin" Value="3,0"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="track" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="knob" Property="Fill" Value="{StaticResource AccentText}"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Grid Width="20" Height="20" VerticalAlignment="Center">
                <Ellipse x:Name="outer" Fill="{StaticResource ControlBg}" Stroke="{StaticResource ToggleStroke}" StrokeThickness="1"/>
                <Ellipse x:Name="dot" Width="0" Height="0" Fill="{StaticResource AccentText}"/>
              </Grid>
              <ContentPresenter Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="outer" Property="Fill" Value="{StaticResource Accent}"/>
                <Setter TargetName="outer" Property="Stroke" Value="{StaticResource Accent}"/>
                <Setter TargetName="dot" Property="Width" Value="8"/>
                <Setter TargetName="dot" Property="Height" Value="8"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Text boxes (Tag = placeholder) -->
    <Style TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Background" Value="{StaticResource InputBg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlStroke}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Text}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Padding" Value="8,0"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Grid>
              <Border x:Name="bd" CornerRadius="4" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"/>
              <Border x:Name="line" CornerRadius="4" BorderThickness="0,0,0,2" BorderBrush="{StaticResource Accent}" Visibility="Collapsed"/>
              <TextBlock x:Name="ph" Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" Foreground="{StaticResource Text3}"
                         Margin="11,0,8,0" VerticalAlignment="Center" IsHitTestVisible="False" Visibility="Collapsed" TextTrimming="CharacterEllipsis"/>
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                            Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="Text" Value=""><Setter TargetName="ph" Property="Visibility" Value="Visible"/></Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{StaticResource InputHover}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource InputFocus}"/>
                <Setter TargetName="line" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="LogBox" TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource Text2}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="CaretBrush" Value="{StaticResource Text}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <ScrollViewer x:Name="PART_ContentHost" Background="Transparent" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ComboBox -->
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Grid Margin="0,1">
              <Border x:Name="bd" CornerRadius="4" Padding="12,7" Background="Transparent"><ContentPresenter/></Border>
              <Rectangle x:Name="pill" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" Fill="{StaticResource Accent}"
                         HorizontalAlignment="Left" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="bd" Property="Background" Value="{StaticResource Subtle}"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Subtle}"/>
                <Setter TargetName="pill" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Background" Value="{StaticResource ControlBg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlStroke}"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Padding" Value="12,0,32,0"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="bd" CornerRadius="4" BorderThickness="1"
                            Background="{Binding Background, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                            BorderBrush="{Binding BorderBrush, RelativeSource={RelativeSource AncestorType=ComboBox}}">
                      <TextBlock Text="&#xE70D;" FontFamily="{StaticResource Icons}" FontSize="10" Foreground="{StaticResource Text2}"
                                 HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{StaticResource ControlHover}"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter IsHitTestVisible="False" Margin="{TemplateBinding Padding}" VerticalAlignment="Center" HorizontalAlignment="Left"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" VerticalOffset="4" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade"
                     IsOpen="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}}">
                <Border Background="{StaticResource Flyout}" BorderBrush="{StaticResource FlyoutStroke}" BorderThickness="1" CornerRadius="8" Padding="4"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                  <ScrollViewer MaxHeight="300"><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Slider with a centre detent mark (exposure is bipolar) -->
    <Style x:Key="SliderRepeat" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FluentSlider" TargetType="Slider">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Height="28" Background="Transparent">
              <Border Height="4" CornerRadius="2" Background="{StaticResource Track}" Margin="10,0" VerticalAlignment="Center"/>
              <Rectangle Width="2" Height="12" RadiusX="1" RadiusY="1" Fill="{StaticResource Text3}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource SliderRepeat}" Command="Slider.DecreaseLarge"/></Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource SliderRepeat}" Command="Slider.IncreaseLarge"/></Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Grid Width="20" Height="20" Background="Transparent">
                          <Ellipse Fill="{StaticResource ThumbBg}" Stroke="{StaticResource ControlStroke}" StrokeThickness="1"/>
                          <Ellipse x:Name="inner" Width="12" Height="12" Fill="{StaticResource Accent}"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="inner" Property="Width" Value="14"/><Setter TargetName="inner" Property="Height" Value="14"/>
                          </Trigger>
                          <Trigger Property="IsDragging" Value="True">
                            <Setter TargetName="inner" Property="Width" Value="10"/><Setter TargetName="inner" Property="Height" Value="10"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="4"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Background" Value="{StaticResource Track}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" CornerRadius="2" Background="{TemplateBinding Background}"/>
              <Border x:Name="PART_Indicator" CornerRadius="2" Background="{TemplateBinding Foreground}" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Thin overlay-style scrollbars -->
    <Style x:Key="ScrollThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="bd" CornerRadius="3" Background="{StaticResource Text3}" Margin="3,2"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Margin" Value="2,2"/><Setter TargetName="bd" Property="Background" Value="{StaticResource Text2}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ScrollThumbH" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="bd" CornerRadius="3" Background="{StaticResource Text3}" Margin="2,3"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True"><Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb></Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track"><Track.Thumb><Thumb Style="{StaticResource ScrollThumbH}"/></Track.Thumb></Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- Queue list -->
    <Style x:Key="QueueList" TargetType="ListBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBox">
            <ScrollViewer Focusable="False" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="QueueItem" TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Grid Margin="0,1,4,1">
              <Border x:Name="bd" CornerRadius="6" Background="Transparent" Padding="12,8"><ContentPresenter/></Border>
              <Rectangle x:Name="pill" Width="3" Height="18" RadiusX="1.5" RadiusY="1.5" Fill="{StaticResource Accent}"
                         HorizontalAlignment="Left" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{StaticResource Subtle}"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Subtle}"/>
                <Setter TargetName="pill" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Pivot-style tabs -->
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <TabPanel IsItemsHost="True" Margin="4,0,0,6"/>
              <ContentPresenter x:Name="PART_SelectedContentHost" Grid.Row="1" ContentSource="SelectedContent"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="{StaticResource Text2}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Grid Background="Transparent" Margin="0,0,20,0" Height="36">
              <ContentPresenter ContentSource="Header" VerticalAlignment="Center"/>
              <Rectangle x:Name="ind" Height="3" Width="16" RadiusX="1.5" RadiusY="1.5" Fill="{StaticResource Accent}"
                         VerticalAlignment="Bottom" HorizontalAlignment="Center" Visibility="Hidden"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="{StaticResource Text}"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="ind" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ContextMenu">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="HasDropShadow" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContextMenu">
            <Border Background="{StaticResource Flyout}" BorderBrush="{StaticResource FlyoutStroke}" BorderThickness="1" CornerRadius="8" Padding="4" MinWidth="200">
              <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="MenuItem">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem">
            <Border x:Name="bd" Background="Transparent" CornerRadius="4" Padding="12,8" Margin="0,1">
              <ContentPresenter ContentSource="Header" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="bd" Property="Background" Value="{StaticResource Subtle}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="{StaticResource Flyout}" BorderBrush="{StaticResource FlyoutStroke}" BorderThickness="1" CornerRadius="4" Padding="8,5">
              <ContentPresenter TextElement.FontSize="12"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="20,14,20,20">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>

    <!-- Header -->
    <Grid Margin="2,0,2,16">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Image Source="{StaticResource AppIcon}" Width="32" Height="32" Margin="0,0,12,0"/>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="Ideal Video Encoder" FontFamily="Segoe UI Variable Display, Segoe UI" FontSize="18" FontWeight="SemiBold"/>
          <TextBlock Text="HEVC and AV1, 10-bit &#x00B7; LUT and range aware" Style="{StaticResource Caption}"/>
        </StackPanel>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
        <TextBlock Text="&#xE9D9;" Style="{StaticResource Icon}" Foreground="{StaticResource Text3}" Margin="0,0,6,0"/>
        <TextBlock x:Name="txtCpu" Text="CPU --" Style="{StaticResource Caption}" VerticalAlignment="Center" MinWidth="64"/>
      </StackPanel>
    </Grid>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*" MinWidth="520"/>
        <ColumnDefinition Width="16"/>
        <ColumnDefinition Width="380"/>
      </Grid.ColumnDefinitions>

      <!-- Left: preview + queue -->
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="5*" MinHeight="240"/>
          <RowDefinition Height="16"/>
          <RowDefinition Height="4*" MinHeight="200"/>
        </Grid.RowDefinitions>

        <Border Style="{StaticResource Card}" Padding="0">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border Background="Black" CornerRadius="7,7,0,0">
              <Grid>
                <StackPanel x:Name="pnlPlaceholder" VerticalAlignment="Center" HorizontalAlignment="Center">
                  <TextBlock Text="&#xE714;" Style="{StaticResource Icon}" FontSize="36" Foreground="#59FFFFFF" HorizontalAlignment="Center"/>
                  <TextBlock Text="Live preview" Foreground="#E6FFFFFF" FontSize="15" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,12,0,4"/>
                  <TextBlock Text="Select a clip and press Preview. Exposure, LUT and trim changes apply instantly."
                             Foreground="#99FFFFFF" FontSize="12" TextAlignment="Center" TextWrapping="Wrap" MaxWidth="320"/>
                </StackPanel>
                <Border x:Name="bdrVideo" Margin="6" Visibility="Collapsed"/>
              </Grid>
            </Border>
            <Grid Grid.Row="1" Margin="12,8">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel Orientation="Horizontal">
                <Button x:Name="btnPreview" Style="{StaticResource AccentButton}" ToolTip="Preview the selected clip (Enter / double-click)">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE768;" Style="{StaticResource Icon}" Margin="0,0,8,0"/>
                    <TextBlock Text="Preview"/>
                  </StackPanel>
                </Button>
                <Button x:Name="btnPause" Style="{StaticResource SubtleButton}" Margin="6,0,0,0" Width="36" ToolTip="Play / pause" IsEnabled="False">
                  <TextBlock x:Name="txtPauseIcon" Text="&#xE769;" Style="{StaticResource Icon}"/>
                </Button>
                <Button x:Name="btnStop" Style="{StaticResource SubtleButton}" Width="36" ToolTip="Stop preview" IsEnabled="False">
                  <TextBlock Text="&#xE71A;" Style="{StaticResource Icon}"/>
                </Button>
              </StackPanel>
              <TextBlock x:Name="txtNowPlaying" Grid.Column="1" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"
                         VerticalAlignment="Center" Margin="12,0"/>
              <Button x:Name="btnPopOut" Grid.Column="2" Style="{StaticResource SubtleButton}" ToolTip="Open the selected clip in a separate mpv.net window">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE8A7;" Style="{StaticResource Icon}" Margin="0,0,8,0"/>
                  <TextBlock Text="Open in mpv.net"/>
                </StackPanel>
              </Button>
            </Grid>
          </Grid>
        </Border>

        <Border Grid.Row="2" Style="{StaticResource Card}" Padding="12,6,8,10">
          <Grid>
            <TabControl x:Name="tabMain">
              <TabItem x:Name="tabQueue" Header="Queue">
                <Grid>
                  <ListBox x:Name="lstQueue" Style="{StaticResource QueueList}" ItemContainerStyle="{StaticResource QueueItem}" SelectionMode="Extended">
                    <ListBox.ItemTemplate>
                      <DataTemplate>
                        <Grid>
                          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                          <Border Width="36" Height="36" CornerRadius="6" Background="{StaticResource Subtle}" Margin="0,0,12,0" VerticalAlignment="Center">
                            <TextBlock Text="&#xE714;" Style="{StaticResource Icon}" FontSize="16" HorizontalAlignment="Center" Foreground="{StaticResource Text2}"/>
                          </Border>
                          <StackPanel Grid.Column="1" VerticalAlignment="Center">
                            <TextBlock Text="{Binding Name}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                            <TextBlock Text="{Binding Detail}" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                            <TextBlock Text="{Binding Note}" FontSize="12" Foreground="{StaticResource Accent}" TextTrimming="CharacterEllipsis" Margin="0,2,0,0">
                              <TextBlock.Style>
                                <Style TargetType="TextBlock">
                                  <Style.Triggers><Trigger Property="Text" Value=""><Setter Property="Visibility" Value="Collapsed"/></Trigger></Style.Triggers>
                                </Style>
                              </TextBlock.Style>
                            </TextBlock>
                            <ProgressBar x:Name="bar" Value="{Binding Progress, Mode=OneWay}" Maximum="100" Height="3" Margin="0,6,0,0" Visibility="Collapsed"/>
                          </StackPanel>
                          <Border x:Name="badge" Grid.Column="2" CornerRadius="10" Padding="10,3" Margin="12,0,0,0" VerticalAlignment="Center" Background="{StaticResource Subtle}">
                            <TextBlock x:Name="badgeText" Text="{Binding Status}" FontSize="12" Foreground="{StaticResource Text2}"/>
                          </Border>
                        </Grid>
                        <DataTemplate.Triggers>
                          <DataTrigger Binding="{Binding StatusKey}" Value="active">
                            <Setter TargetName="bar" Property="Visibility" Value="Visible"/>
                            <Setter TargetName="badge" Property="Background" Value="{StaticResource AccentBg}"/>
                            <Setter TargetName="badgeText" Property="Foreground" Value="{StaticResource Accent}"/>
                          </DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="done">
                            <Setter TargetName="badge" Property="Background" Value="{StaticResource SuccessBg}"/>
                            <Setter TargetName="badgeText" Property="Foreground" Value="{StaticResource Success}"/>
                          </DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="error">
                            <Setter TargetName="badge" Property="Background" Value="{StaticResource DangerBg}"/>
                            <Setter TargetName="badgeText" Property="Foreground" Value="{StaticResource Danger}"/>
                          </DataTrigger>
                        </DataTemplate.Triggers>
                      </DataTemplate>
                    </ListBox.ItemTemplate>
                  </ListBox>
                  <StackPanel x:Name="pnlEmpty" VerticalAlignment="Center" HorizontalAlignment="Center" IsHitTestVisible="False">
                    <TextBlock Text="&#xE896;" Style="{StaticResource Icon}" FontSize="28" Foreground="{StaticResource Text3}" HorizontalAlignment="Center"/>
                    <TextBlock Text="Drop clips here" FontSize="14" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,10,0,2"/>
                    <TextBlock Text="or use Add clips. .MOV and .MP4, files or folders." Style="{StaticResource Caption}" HorizontalAlignment="Center"/>
                  </StackPanel>
                </Grid>
              </TabItem>
              <TabItem x:Name="tabAnalysis" Header="Analysis">
                <Grid>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <Grid Margin="4,2,4,10">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Style="{StaticResource Caption}" VerticalAlignment="Center" Margin="0,0,12,0"
                               Text="Analyses each clip on its own (the selected clips, or every clip from the arrow menu): short sample encodes with your current look and grain settings, scored against the source with VMAF, give each clip its own CRF and bitrate cap. Several minutes per 6K clip."/>
                    <ComboBox x:Name="cmbTarget" Grid.Column="1" Width="200" ToolTip="Quality target. VMAF 100 = indistinguishable from the source">
                      <ComboBoxItem Content="High (VMAF 93)"/>
                      <ComboBoxItem Content="Transparent (VMAF 95)" IsSelected="True"/>
                      <ComboBoxItem Content="Archival (VMAF 97)"/>
                    </ComboBox>
                    <Button x:Name="btnAnalyze" Grid.Column="2" Style="{StaticResource AccentButton}" Margin="8,0,0,0" ToolTip="Analyse the selected clips">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xE9D9;" Style="{StaticResource Icon}" Margin="0,0,8,0"/>
                        <TextBlock x:Name="txtAnalyzeLabel" Text="Analyse selected"/>
                      </StackPanel>
                    </Button>
                    <Button x:Name="btnAnalyzeMore" Grid.Column="3" Style="{StaticResource AccentButton}" Margin="2,0,0,0" Width="32" Padding="0"
                            ToolTip="More analysis options" AutomationProperties.Name="More analysis options">
                      <TextBlock Text="&#xE70D;" Style="{StaticResource Icon}" FontSize="10"/>
                      <Button.ContextMenu>
                        <ContextMenu Placement="Bottom">
                          <MenuItem Header="Analyse all clips"/>
                          <MenuItem Header="Analyse selected clips"/>
                        </ContextMenu>
                      </Button.ContextMenu>
                    </Button>
                  </Grid>
                  <ListBox x:Name="lstAnalysis" Grid.Row="1" Style="{StaticResource QueueList}" ItemContainerStyle="{StaticResource QueueItem}">
                    <ListBox.ItemTemplate>
                      <DataTemplate>
                        <Grid>
                          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                          <StackPanel>
                            <TextBlock Text="{Binding Name}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                            <TextBlock Text="{Binding Detail}" Style="{StaticResource Caption}" Margin="0,4,0,0" LineHeight="18"/>
                            <ProgressBar x:Name="bar" Value="{Binding Progress, Mode=OneWay}" Maximum="100" Height="3" Margin="0,8,0,0" Visibility="Collapsed"/>
                          </StackPanel>
                          <Border x:Name="badge" Grid.Column="1" CornerRadius="10" Padding="10,3" Margin="12,0,0,0" VerticalAlignment="Top" Background="{StaticResource Subtle}">
                            <TextBlock x:Name="badgeText" Text="{Binding Status}" FontSize="12" Foreground="{StaticResource Text2}"/>
                          </Border>
                        </Grid>
                        <DataTemplate.Triggers>
                          <DataTrigger Binding="{Binding StatusKey}" Value="active">
                            <Setter TargetName="bar" Property="Visibility" Value="Visible"/>
                            <Setter TargetName="badge" Property="Background" Value="{StaticResource AccentBg}"/>
                            <Setter TargetName="badgeText" Property="Foreground" Value="{StaticResource Accent}"/>
                          </DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="done">
                            <Setter TargetName="badge" Property="Background" Value="{StaticResource SuccessBg}"/>
                            <Setter TargetName="badgeText" Property="Foreground" Value="{StaticResource Success}"/>
                          </DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="error">
                            <Setter TargetName="badge" Property="Background" Value="{StaticResource DangerBg}"/>
                            <Setter TargetName="badgeText" Property="Foreground" Value="{StaticResource Danger}"/>
                          </DataTrigger>
                        </DataTemplate.Triggers>
                      </DataTemplate>
                    </ListBox.ItemTemplate>
                  </ListBox>
                  <StackPanel x:Name="pnlAnaEmpty" Grid.Row="1" VerticalAlignment="Center" HorizontalAlignment="Center" IsHitTestVisible="False">
                    <TextBlock Text="&#xE9D9;" Style="{StaticResource Icon}" FontSize="28" Foreground="{StaticResource Text3}" HorizontalAlignment="Center"/>
                    <TextBlock Text="Find the right CRF and cap for your footage" FontSize="14" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,10,0,2"/>
                    <TextBlock Text="Pick a quality target and press Analyse." Style="{StaticResource Caption}" HorizontalAlignment="Center"/>
                  </StackPanel>
                  <Border x:Name="bdrAnaSummary" Grid.Row="2" Background="{StaticResource AccentBg}" CornerRadius="6" Padding="14,10" Margin="0,8,4,0" Visibility="Collapsed">
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBlock x:Name="txtAnaSummary" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,12,0"/>
                      <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <Button x:Name="btnAnaPerClip" Style="{StaticResource AccentButton}" Content="Use per clip" Margin="0,0,8,0"
                                ToolTip="Each analysed clip encodes with its own CRF and cap"/>
                        <Button x:Name="btnAnaApply" Content="Apply to all" ToolTip="Use one CRF and cap for everything: the most demanding clip's CRF and the largest cap"/>
                      </StackPanel>
                    </Grid>
                  </Border>
                </Grid>
              </TabItem>
              <TabItem Header="Log">
                <TextBox x:Name="txtLog" Style="{StaticResource LogBox}" Margin="4,0,0,0"/>
              </TabItem>
            </TabControl>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,2,0,0">
              <Button x:Name="btnAdd" ToolTip="Add clips to the queue">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE710;" Style="{StaticResource Icon}" Margin="0,0,8,0"/>
                  <TextBlock Text="Add clips"/>
                </StackPanel>
              </Button>
              <Button x:Name="btnRemove" Style="{StaticResource SubtleButton}" Width="36" Margin="6,0,0,0" ToolTip="Remove selected (Delete)">
                <TextBlock Text="&#xE74D;" Style="{StaticResource Icon}"/>
              </Button>
              <Button x:Name="btnClear" Style="{StaticResource SubtleButton}" ToolTip="Remove every clip from the queue">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE894;" Style="{StaticResource Icon}" Margin="0,0,6,0"/>
                  <TextBlock Text="Clear"/>
                </StackPanel>
              </Button>
            </StackPanel>
          </Grid>
        </Border>
      </Grid>

      <!-- Right: settings + run -->
      <Grid Grid.Column="2">
        <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,0,-12,0" Padding="0,0,12,0">
          <StackPanel>

            <Border Style="{StaticResource Card}" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock Text="Look" Style="{StaticResource Section}"/>
                <CheckBox x:Name="chkLut" Style="{StaticResource Toggle}" Content="Apply LUT"/>
                <Grid Margin="0,10,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <Border Background="{StaticResource InputBg}" BorderBrush="{StaticResource ControlStroke}" BorderThickness="1" CornerRadius="4" Padding="10,0" Height="32">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                      <TextBlock Text="&#xE790;" Style="{StaticResource Icon}" Foreground="{StaticResource Text2}" Margin="0,0,8,0"/>
                      <TextBlock x:Name="txtLutName" Text="No LUT selected" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <Button x:Name="btnLut" Grid.Column="1" Content="Browse" Margin="8,0,0,0"/>
                </Grid>
                <Rectangle Style="{StaticResource DividerLine}"/>
                <Grid>
                  <TextBlock Text="Exposure" VerticalAlignment="Center"/>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                    <TextBlock x:Name="txtEv" Text="0.0 EV" Foreground="{StaticResource Text2}" VerticalAlignment="Center"/>
                    <Button x:Name="btnEvReset" Style="{StaticResource SubtleButton}" Width="28" Height="28" Margin="6,0,0,0" ToolTip="Reset to 0 (or double-click the slider)">
                      <TextBlock Text="&#xE72C;" Style="{StaticResource Icon}" FontSize="12"/>
                    </Button>
                  </StackPanel>
                </Grid>
                <Slider x:Name="sldEv" Style="{StaticResource FluentSlider}" Minimum="-2" Maximum="2" Value="0" SmallChange="0.1" LargeChange="0.5"
                        TickFrequency="0.1" IsSnapToTickEnabled="True" IsMoveToPointEnabled="True" Margin="-10,2,-10,0"/>
                <Grid Margin="0,0,0,6">
                  <TextBlock Text="-2" FontSize="11" Foreground="{StaticResource Text3}"/>
                  <TextBlock Text="+2" FontSize="11" Foreground="{StaticResource Text3}" HorizontalAlignment="Right"/>
                </Grid>
                <TextBlock Text="Stops, applied before the LUT using the F-Log2 curve." Style="{StaticResource Caption}"/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock Text="Encoding" Style="{StaticResource Section}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Codec"/>
                    <TextBlock x:Name="txtCodecHint" Style="{StaticResource Caption}" Margin="0,2,12,0"/>
                  </StackPanel>
                  <ComboBox x:Name="cmbCodec" Grid.Column="1" Width="150" VerticalAlignment="Center">
                    <ComboBoxItem Content="HEVC (x265)" IsSelected="True"/>
                    <ComboBoxItem Content="AV1 (SVT-AV1)"/>
                  </ComboBox>
                </Grid>
                <Rectangle Style="{StaticResource DividerLine}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Quality target"/>
                    <TextBlock x:Name="txtTargetHint" Style="{StaticResource Caption}" Margin="0,2,12,0"/>
                  </StackPanel>
                  <ComboBox x:Name="cmbQualityTarget" Grid.Column="1" Width="150" VerticalAlignment="Center" ToolTip="VMAF 100 = indistinguishable from the source">
                    <ComboBoxItem Content="Off (use CRF)" IsSelected="True"/>
                    <ComboBoxItem Content="VMAF 93"/>
                    <ComboBoxItem Content="VMAF 95"/>
                    <ComboBoxItem Content="VMAF 97"/>
                  </ComboBox>
                </Grid>
                <Rectangle Style="{StaticResource DividerLine}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Quality (CRF)"/>
                    <TextBlock x:Name="txtCrfHint" Style="{StaticResource Caption}" Margin="0,2,12,0"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBox x:Name="txtCrf" Width="52" HorizontalContentAlignment="Center" Text="20"/>
                    <CheckBox x:Name="chkAutoCrf" Style="{StaticResource Toggle}" Content="Auto" Margin="12,0,0,0"/>
                  </StackPanel>
                </Grid>
                <Rectangle Style="{StaticResource DividerLine}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Grain retention"/>
                    <TextBlock Text="Keeps grain instead of smoothing it; costs bitrate. Auto raises it for F-Log2 and noisy clips." Style="{StaticResource Caption}" Margin="0,2,12,0"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <ComboBox x:Name="cmbGrain" Width="88" Padding="10,0,28,0">
                      <ComboBoxItem Content="Off" IsSelected="True"/>
                      <ComboBoxItem Content="Light"/>
                      <ComboBoxItem Content="Strong"/>
                    </ComboBox>
                    <CheckBox x:Name="chkAutoGrain" Style="{StaticResource Toggle}" Content="Auto" Margin="12,0,0,0"/>
                  </StackPanel>
                </Grid>
                <Rectangle Style="{StaticResource DividerLine}"/>
                <CheckBox x:Name="chkVbr" Style="{StaticResource Toggle}">
                  <StackPanel>
                    <TextBlock Text="Bitrate cap (constrained VBR)"/>
                    <TextBlock Text="CRF quality with VBV peaks capped; buffer is 2x the cap." Style="{StaticResource Caption}" Margin="0,2,0,0"/>
                  </StackPanel>
                </CheckBox>
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                  <TextBox x:Name="txtMaxRate" Width="72" HorizontalContentAlignment="Center" Text="35"/>
                  <TextBlock Text="Mbps max" Foreground="{StaticResource Text2}" VerticalAlignment="Center" Margin="10,0,0,0"/>
                </StackPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock Text="Trim" Style="{StaticResource Section}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBox x:Name="txtStart" Tag="Start (s or mm:ss)"/>
                  <TextBox x:Name="txtEnd" Grid.Column="2" Tag="End (s or mm:ss)"/>
                </Grid>
                <TextBlock Text="Leave empty for the whole clip. The preview loops this range." Style="{StaticResource Caption}" Margin="0,8,0,0"/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Output" Style="{StaticResource Section}"/>
                <RadioButton x:Name="rbSource" GroupName="out" Content="Next to each source clip" IsChecked="True"/>
                <RadioButton x:Name="rbCustom" GroupName="out" Content="Custom folder" Margin="0,8,0,0"/>
                <Grid Margin="30,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox x:Name="txtOutFolder" Tag="Choose a folder"/>
                  <Button x:Name="btnOutFolder" Grid.Column="1" Margin="8,0,0,0" Width="36" Padding="0" ToolTip="Browse for a folder">
                    <TextBlock Text="&#xE838;" Style="{StaticResource Icon}"/>
                  </Button>
                </Grid>
                <TextBlock Text="Subfolder" Margin="0,14,0,6"/>
                <TextBox x:Name="txtSubfolder" Tag="None (save directly in the folder)"/>
                <Border Background="{StaticResource Subtle}" CornerRadius="4" Padding="10,8" Margin="0,10,0,0">
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <TextBlock Text="&#xE8B7;" Style="{StaticResource Icon}" FontSize="12" Foreground="{StaticResource Text2}" VerticalAlignment="Top" Margin="0,2,8,0"/>
                    <TextBlock x:Name="txtOutPreview" Grid.Column="1" Style="{StaticResource Caption}"/>
                  </Grid>
                </Border>
                <Rectangle Style="{StaticResource DividerLine}"/>
                <CheckBox x:Name="chkCsv" Style="{StaticResource Toggle}" Content="Write CSV log"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="txtCsvPath" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                  <Button x:Name="btnCsv" Grid.Column="1" Style="{StaticResource SubtleButton}" Content="Change" Margin="8,0,-8,0"/>
                </Grid>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,12,0,0">
          <StackPanel>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="txtOverall" Text="Ready" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" Margin="0,0,10,0"/>
              <TextBlock x:Name="txtEta" Grid.Column="1" Style="{StaticResource Caption}" TextWrapping="NoWrap" VerticalAlignment="Center"/>
            </Grid>
            <ProgressBar x:Name="prgOverall" Maximum="100" Margin="0,10,0,14"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <ComboBox x:Name="cmbStart" Width="104" ToolTip="When to start">
                <ComboBoxItem Content="Now" IsSelected="True"/>
                <ComboBoxItem Content="Later at"/>
              </ComboBox>
              <Button x:Name="btnStart" Grid.Column="1" Style="{StaticResource AccentButton}" Margin="8,0">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE768;" Style="{StaticResource Icon}" Margin="0,0,8,0"/>
                  <TextBlock x:Name="txtStartLabel" Text="Start"/>
                </StackPanel>
              </Button>
              <Button x:Name="btnCancel" Grid.Column="2" Content="Cancel" IsEnabled="False"/>
            </Grid>
            <Grid x:Name="pnlSchedule" Margin="0,10,0,0" Visibility="Collapsed">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBox x:Name="txtStartTime" Width="104" HorizontalContentAlignment="Center" Tag="e.g. 04:30" ToolTip="Any time: 04:30, 4:30 pm, 0430, 4pm"/>
              <TextBlock x:Name="txtScheduleHint" Grid.Column="1" Style="{StaticResource Caption}" VerticalAlignment="Center" Margin="10,0,0,0"/>
            </Grid>
          </StackPanel>
        </Border>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@

# ========== Build window ==========
$xamlText = $Xaml
foreach ($k in $Palette.Keys) { $xamlText = $xamlText.Replace("@$k@", $Palette[$k]) }
$window = [Windows.Markup.XamlReader]::Parse($xamlText)
foreach ($m in [regex]::Matches($xamlText, 'x:Name="((?:btn|txt|chk|rb|sld|cmb|lst|prg|pnl|tab|bdr)\w*)"')) {
    Set-Variable -Name $m.Groups[1].Value -Value $window.FindName($m.Groups[1].Value) -Scope Script
}
$window.Icon = $window.FindResource('AppIcon')

# Fit the default size to smaller screens
$wa = [System.Windows.SystemParameters]::WorkArea
$window.Width  = [math]::Min(1280, $wa.Width * 0.94)
$window.Height = [math]::Min(820, $wa.Height * 0.94)

# Video host: a black WinForms panel whose HWND libmpv renders into
$videoPanel = New-Object System.Windows.Forms.Panel
$videoPanel.BackColor = [System.Drawing.Color]::Black
$videoHost = New-Object System.Windows.Forms.Integration.WindowsFormsHost
$videoHost.Background = [System.Windows.Media.Brushes]::Black
$videoHost.Child = $videoPanel
$bdrVideo.Child = $videoHost

# ========== State ==========
$inv    = [System.Globalization.CultureInfo]::InvariantCulture
$dot    = [string][char]0x00B7
# mpv.net install: next to the app, the machine-wide installer location, or the per-user one
$AppDir = if ($PSScriptRoot) { $PSScriptRoot } else { [AppDomain]::CurrentDomain.BaseDirectory }
$MpvNetDir = @((Join-Path $AppDir 'mpv.net'), $AppDir, (Join-Path $env:ProgramFiles 'mpv.net'), (Join-Path $env:LOCALAPPDATA 'Programs\mpv.net')) |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ 'libmpv-2.dll') } | Select-Object -First 1
if (-not $MpvNetDir) { $MpvNetDir = Join-Path $env:ProgramFiles 'mpv.net' }
$VideoExt  = @('.mov', '.mp4')
$SettingsPath = Join-Path $env:APPDATA 'Ideal Video Encoder\settings.json'
# Carry settings over from the app's previous name
$OldSettingsPath = Join-Path $env:APPDATA 'Fujifilm Video Compressor\settings.json'
if (-not (Test-Path -LiteralPath $SettingsPath) -and (Test-Path -LiteralPath $OldSettingsPath)) {
    try { New-Item -ItemType Directory -Path (Split-Path $SettingsPath) -Force | Out-Null; Copy-Item -LiteralPath $OldSettingsPath -Destination $SettingsPath } catch {}
}

$script:Items       = New-Object 'System.Collections.ObjectModel.ObservableCollection[IdealVE.QueueItem]'
$script:LutPath     = ''
$script:CsvPath     = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ffmpeg_log.csv'
$script:RunState    = 'idle'     # idle | scheduled | running
$script:ScheduledAt = $null
$script:Sync        = [hashtable]::Synchronized(@{ Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'; Cancel = $false; Proc = $null })
$script:Worker      = $null
$script:WorkerRs    = $null
$script:WorkerHandle = $null
$script:Mpv         = $null
$script:MpvLoaded   = $false
$script:PreviewPath = $null
$script:RangeCache  = @{}
$script:Cpu         = $null
$script:Tick        = 0
$lstQueue.ItemsSource = $script:Items
$script:AnaItems    = New-Object 'System.Collections.ObjectModel.ObservableCollection[IdealVE.QueueItem]'
$script:AnaSuggest  = $null
$script:AnaResults    = @{}   # path -> latest analysis result (not yet applied)
$script:ClipOverrides = @{}   # path -> per-clip CRF/cap/grain chosen by analysis ("Use per clip" or a quality-target run)
$lstAnalysis.ItemsSource = $script:AnaItems

# ========== UI helpers ==========
function Write-Log([string]$text) {
    $txtLog.AppendText(("[{0}] {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $text))
    $txtLog.ScrollToEnd()
}

function Show-Warning([string]$text) {
    Write-Log $text
    [void][System.Windows.MessageBox]::Show($window, $text, 'Ideal Video Encoder', 'OK', 'Warning')
}

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:0.00} GB' -f ($bytes / 1GB)) }
    return ('{0:0} MB' -f ($bytes / 1MB))
}

function Format-Duration([double]$sec) {
    $ts = [TimeSpan]::FromSeconds([math]::Round($sec))
    if ($ts.TotalHours -ge 1) { return $ts.ToString('h\:mm\:ss') }
    return $ts.ToString('m\:ss')
}

# "90", "1:30" or "00:01:30.5" -> seconds; $null when empty, NaN when invalid
function ConvertTo-Seconds([string]$text) {
    $t = "$text".Trim()
    if (-not $t) { return $null }
    $parts = $t.Split(':')
    if ($parts.Count -gt 3) { return [double]::NaN }
    $total = 0.0
    foreach ($p in $parts) {
        $v = 0.0
        if (-not [double]::TryParse($p, [System.Globalization.NumberStyles]::Float, $inv, [ref]$v) -or $v -lt 0) { return [double]::NaN }
        $total = $total * 60 + $v
    }
    return $total
}

function Find-QueueItem([string]$path) {
    foreach ($it in $script:Items) { if ($it.Path -eq $path) { return $it } }
    return $null
}

function Add-QueueFiles([string[]]$paths) {
    if ($script:RunState -eq 'running') { Write-Log 'The queue is locked while converting.'; return }
    $added = 0
    foreach ($p in $paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $files = @()
        if (Test-Path -LiteralPath $p -PathType Container) {
            $files = @(Get-ChildItem -LiteralPath $p -File | Where-Object { $VideoExt -contains $_.Extension.ToLowerInvariant() } | ForEach-Object { $_.FullName })
        } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
            $files = @($p)
        }
        foreach ($f in $files) {
            $full = [IO.Path]::GetFullPath($f)
            if ($VideoExt -notcontains [IO.Path]::GetExtension($full).ToLowerInvariant()) { continue }
            if (Find-QueueItem $full) { continue }
            $item = New-Object IdealVE.QueueItem
            $item.Name = [IO.Path]::GetFileName($full)
            $item.Path = $full
            $info = @(Format-Size (Get-Item -LiteralPath $full).Length)
            $d = Get-Duration $full
            if ($d -gt 0) { $info += Format-Duration $d }
            $info += [IO.Path]::GetDirectoryName($full)
            $item.Info = $info -join "  $dot  "
            $item.Detail = $item.Info
            $item.Status = 'Queued'
            $item.StatusKey = 'queued'
            $script:Items.Add($item)
            $added++
        }
    }
    if ($added) {
        Write-Log "Added $added clip(s)."
        if (-not $lstQueue.SelectedItem) { $lstQueue.SelectedIndex = 0 }
    }
    Update-QueueState
}

function Update-QueueState {
    $n = $script:Items.Count
    $tabQueue.Header = if ($n) { "Queue ($n)" } else { 'Queue' }
    $pnlEmpty.Visibility = if ($n) { 'Collapsed' } else { 'Visible' }
    $locked = ($script:RunState -eq 'running' -or $script:RunState -eq 'analysing')
    $btnAnalyze.IsEnabled = ($script:RunState -eq 'idle') -and $n -gt 0
    $btnAnalyzeMore.IsEnabled = $btnAnalyze.IsEnabled
    $sel = $lstQueue.SelectedItems.Count
    $txtAnalyzeLabel.Text = if ($sel -gt 1) { "Analyse $sel selected" } elseif ($sel -eq 1) { 'Analyse selected' } else { 'Analyse all' }
    $pnlAnaEmpty.Visibility = if ($script:AnaItems.Count) { 'Collapsed' } else { 'Visible' }
    $btnAdd.IsEnabled = -not $locked
    $btnClear.IsEnabled = (-not $locked) -and $n -gt 0
    $btnRemove.IsEnabled = (-not $locked) -and $lstQueue.SelectedItems.Count -gt 0
    $btnPreview.IsEnabled = $n -gt 0
    $btnPopOut.IsEnabled = $n -gt 0
    Update-OutputPreview
}

# Everything a measured CRF depends on; a per-clip result is only reused when this matches
function Get-LookKey {
    "{0}|{1}|{2}|{3}|{4}" -f (Get-Codec), ([math]::Round($sldEv.Value, 1)).ToString($inv), (Get-CurrentLut), $cmbGrain.SelectedIndex, [bool]$chkAutoGrain.IsChecked
}
function Get-QualityTarget { @(0, 93, 95, 97)[[math]::Max(0, $cmbQualityTarget.SelectedIndex)] }

function Update-OverrideNotes {
    $key = Get-LookKey
    foreach ($it in $script:Items) {
        $ov = $script:ClipOverrides[$it.Path]
        if (-not $ov) { $it.Note = ''; continue }
        $text = "Analysed for VMAF {0}: {1} CRF {2}, {3} Mbps cap" -f $ov.Target, $ov.CodecName, $ov.Crf, $ov.Cap
        $it.Note = if ($ov.Key -eq $key) { $text } else { "$text (made with different settings, not used)" }
    }
}

function Update-Enablement {
    $target = (Get-QualityTarget) -gt 0
    $txtCrf.IsEnabled = -not $chkAutoCrf.IsChecked -and -not $target
    $chkAutoCrf.IsEnabled = -not $target
    $txtTargetHint.Text = if ($target) { 'Each clip is measured first to pick its CRF and cap. Slower.' } else { 'Or measure each clip to hit a VMAF score.' }
    $cmbGrain.IsEnabled = -not $chkAutoGrain.IsChecked
    $txtMaxRate.IsEnabled = [bool]$chkVbr.IsChecked -and -not $target
    $txtMaxRate.ToolTip = if ($target) { 'With a quality target, each clip''s cap comes from its measurement' } else { $null }
    Update-OverrideNotes
    $txtOutFolder.IsEnabled = [bool]$rbCustom.IsChecked
    $btnOutFolder.IsEnabled = [bool]$rbCustom.IsChecked
    $txtCsvPath.Text = $script:CsvPath
    $txtCsvPath.ToolTip = $script:CsvPath
    $txtCsvPath.Opacity = if ($chkCsv.IsChecked) { 1 } else { 0.5 }
    Update-OutputPreview
}

function Get-OutputMode { if ($rbCustom.IsChecked) { 'custom' } else { 'source' } }

# Codec: each keeps its own CRF because the scales differ (x265 0-51, SVT-AV1 0-63)
$script:CrfByCodec = @{ hevc = '21'; av1 = [string](ConvertTo-Av1Crf 21) }
$script:LastCodec = 'hevc'
$script:Loading = $false
function Get-Codec { if ($cmbCodec.SelectedIndex -eq 1) { 'av1' } else { 'hevc' } }
function Get-OutputExt { if ((Get-Codec) -eq 'av1') { '.MP4' } else { '.MOV' } }
function Update-CodecUi {
    if ((Get-Codec) -eq 'av1') {
        $txtCodecHint.Text = 'Smaller files; needs a newer device to play. Saves .MP4.'
        $txtCodecHint.ToolTip = 'Hardware AV1 playback: iPhone 15 Pro / M3 Mac and later, NVIDIA RTX 30+, AMD RX 6000+, Intel 11th gen+. Other devices fall back to software decoding.'
        $txtCrfHint.Text = "Lower is better (0-63). Auto picks $(ConvertTo-Av1Crf 16)-$(ConvertTo-Av1Crf 24) from noise, motion and ISO."
    } else {
        $txtCodecHint.Text = 'Plays almost everywhere, including all Apple devices.'
        $txtCodecHint.ToolTip = $null
        $txtCrfHint.Text = 'Lower is better (0-51). Auto picks 16-24 from noise, motion and ISO.'
    }
}

function Update-OutputPreview {
    $sample = $null
    if ($lstQueue.SelectedItem) { $sample = $lstQueue.SelectedItem.Path } elseif ($script:Items.Count) { $sample = $script:Items[0].Path }
    $mode = Get-OutputMode
    $folder = $txtOutFolder.Text.Trim()
    if ($mode -eq 'custom' -and -not $folder) { $txtOutPreview.Text = 'Choose an output folder.'; return }
    try {
        if ($sample) {
            $dir = Resolve-OutputDir $sample $mode $folder $txtSubfolder.Text
            $txtOutPreview.Text = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($sample) + (Get-OutputExt))
        } else {
            $root = if ($mode -eq 'custom') { $folder } else { '<clip folder>' }
            $sub = $txtSubfolder.Text.Trim().Trim('\', '/')
            $txtOutPreview.Text = if ($sub) { "$root\$sub\<clip>$(Get-OutputExt)" } else { "$root\<clip>$(Get-OutputExt)" }
        }
    } catch { $txtOutPreview.Text = 'Invalid folder name.' }
}

function Set-LutPath([string]$path) {
    $script:LutPath = $path
    if ($path) { $txtLutName.Text = [IO.Path]::GetFileName($path); $txtLutName.ToolTip = $path }
    else { $txtLutName.Text = 'No LUT selected'; $txtLutName.ToolTip = $null }
}

function Get-CurrentLut {
    if ($chkLut.IsChecked -and $script:LutPath -and (Test-Path -LiteralPath $script:LutPath)) { return $script:LutPath }
    return ''
}

function Update-EvLabel {
    $ev = [math]::Round($sldEv.Value, 1)
    $txtEv.Text = $ev.ToString('+0.0;-0.0;0.0', $inv) + ' EV'
}

# ========== Settings ==========
function Save-Settings {
    try {
        $s = [ordered]@{
            LutPath = $script:LutPath; LutEnabled = [bool]$chkLut.IsChecked
            Codec = (Get-Codec); AutoCrf = [bool]$chkAutoCrf.IsChecked; CrfHevc = $(if ((Get-Codec) -eq 'hevc') { $txtCrf.Text } else { $script:CrfByCodec.hevc }); CrfAv1 = $(if ((Get-Codec) -eq 'av1') { $txtCrf.Text } else { $script:CrfByCodec.av1 })
            AutoGrain = [bool]$chkAutoGrain.IsChecked; GrainLevel = $cmbGrain.SelectedIndex; QualityTarget = (Get-QualityTarget); ScheduleTime = $txtStartTime.Text.Trim()
            VbrEnabled = [bool]$chkVbr.IsChecked; MaxRate = $txtMaxRate.Text
            OutputMode = (Get-OutputMode); OutputFolder = $txtOutFolder.Text.Trim(); Subfolder = $txtSubfolder.Text
            CsvEnabled = [bool]$chkCsv.IsChecked; CsvPath = $script:CsvPath
        }
        $dir = Split-Path $SettingsPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $s | ConvertTo-Json | Set-Content -LiteralPath $SettingsPath -Encoding UTF8
    } catch { Write-Log "Could not save settings: $($_.Exception.Message)" }
}

function Import-SettingsCore {
    # Defaults match the original tool
    $script:Loading = $true
    $chkLut.IsChecked = $false; $chkAutoCrf.IsChecked = $false; $txtCrf.Text = '21'
    $chkAutoGrain.IsChecked = $false; $cmbGrain.SelectedIndex = 0
    $chkVbr.IsChecked = $true; $txtMaxRate.Text = '35'
    $rbSource.IsChecked = $true; $txtOutFolder.Text = ''; $txtSubfolder.Text = 'From FFmpeg'
    $chkCsv.IsChecked = $false; $txtStartTime.Text = '04:00'
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return }
    try {
        $s = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
        if ($s.LutPath -and (Test-Path -LiteralPath $s.LutPath)) { Set-LutPath $s.LutPath; $chkLut.IsChecked = [bool]$s.LutEnabled }
        $chkAutoCrf.IsChecked = [bool]$s.AutoCrf
        if ($s.CrfHevc) { $script:CrfByCodec.hevc = [string]$s.CrfHevc } elseif ($s.Crf) { $script:CrfByCodec.hevc = [string]$s.Crf }
        if ($s.CrfAv1) { $script:CrfByCodec.av1 = [string]$s.CrfAv1 }
        if ($s.Codec -eq 'av1') { $cmbCodec.SelectedIndex = 1 }
        $chkAutoGrain.IsChecked = [bool]$s.AutoGrain
        $ti = [array]::IndexOf(@(0, 93, 95, 97), [int]$s.QualityTarget); if ($ti -gt 0) { $cmbQualityTarget.SelectedIndex = $ti }
        if ($s.ScheduleTime) { $txtStartTime.Text = [string]$s.ScheduleTime }
        if ($null -ne $s.GrainLevel -and [int]$s.GrainLevel -ge 0 -and [int]$s.GrainLevel -le 2) { $cmbGrain.SelectedIndex = [int]$s.GrainLevel }
        $chkVbr.IsChecked = [bool]$s.VbrEnabled; if ($s.MaxRate) { $txtMaxRate.Text = $s.MaxRate }
        if ($s.OutputMode -eq 'custom') { $rbCustom.IsChecked = $true }
        if ($null -ne $s.OutputFolder) { $txtOutFolder.Text = $s.OutputFolder }
        if ($null -ne $s.Subfolder) { $txtSubfolder.Text = $s.Subfolder }
        $chkCsv.IsChecked = [bool]$s.CsvEnabled; if ($s.CsvPath) { $script:CsvPath = $s.CsvPath }
    } catch { Write-Log "Could not read settings: $($_.Exception.Message)" }
}

function Import-Settings {
    try { Import-SettingsCore }
    finally {
        # Show the remembered CRF for whichever codec is selected
        $script:LastCodec = Get-Codec
        $txtCrf.Text = $script:CrfByCodec[$script:LastCodec]
        $script:Loading = $false
        Update-CodecUi
    }
}

# ========== Preview (embedded libmpv, mpv.net as fallback/pop-out) ==========
function Get-IsFullCached([string]$path) {
    if (-not $script:RangeCache.ContainsKey($path)) { $script:RangeCache[$path] = [bool](Get-VideoRangeFull $path) }
    return $script:RangeCache[$path]
}

function Get-PreviewTarget {
    if ($lstQueue.SelectedItem) { return $lstQueue.SelectedItem }
    if ($script:Items.Count) { return $script:Items[0] }
    return $null
}

function Show-Video([bool]$on) {
    $bdrVideo.Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
    $pnlPlaceholder.Visibility = if ($on) { 'Collapsed' } else { 'Visible' }
    $btnPause.IsEnabled = $on
    $btnStop.IsEnabled = $on
    if (-not $on) { $txtNowPlaying.Text = '' }
}

# Playback tuning shared by the embedded preview and "Open in mpv.net". Software decoding on all cores:
# 4:2:2 HEVC from recent cameras has no GPU decoder on most PCs, and probing for one stalls playback.
# Cheap bilinear scaling for 6K, a decode queue, and a large demuxer cache for high-bitrate files.
$MpvTuning = [ordered]@{
    'vd-lavc-threads'        = '0'
    'hwdec'                  = 'no'
    'vo'                     = 'gpu-next'
    'gpu-api'                = 'vulkan'      # falls back to d3d11 automatically if Vulkan can't start
    'vd-queue-enable'        = 'yes'
    'hr-seek'                = 'no'
    'scale'                  = 'bilinear'
    'cscale'                 = 'bilinear'
    'dscale'                 = 'bilinear'
    'sws-scaler'             = 'fast-bilinear'
    'demuxer-max-bytes'      = '2000MiB'
    'demuxer-max-back-bytes' = '500MiB'
}
$script:MpvGpuApi = 'vulkan'

function Initialize-Mpv {
    if ($script:Mpv -and $script:Mpv.IsAlive) { return $true }
    $dll = Join-Path $MpvNetDir 'libmpv-2.dll'
    if (-not (Test-Path -LiteralPath $dll)) { Write-Log "Embedded preview needs mpv.net ($dll not found)."; return $false }
    try {
        if (-not $script:MpvLoaded) {
            if (-not [IdealVE.Mpv]::LoadFrom($dll)) { throw "could not load $dll" }
            $script:MpvLoaded = $true
        }
        $bdrVideo.UpdateLayout()
        $m = New-Object IdealVE.Mpv
        $opts = [ordered]@{ 'wid' = $videoPanel.Handle.ToInt64().ToString() }
        foreach ($k in $MpvTuning.Keys) { $opts[$k] = $MpvTuning[$k] }
        $opts['gpu-api'] = $script:MpvGpuApi
        $more = [ordered]@{
            'loop-file' = 'inf'
            'keep-open' = 'yes'
            'idle' = 'yes'
            'force-window' = 'yes'
            'osc' = 'yes'
            'input-default-bindings' = 'yes'
            'input-vo-keyboard' = 'yes'
            'terminal' = 'no'
            'config' = 'no'
        }
        foreach ($k in $more.Keys) { $opts[$k] = $more[$k] }
        foreach ($k in $opts.Keys) {
            if ($m.SetOption($k, $opts[$k]) -lt 0) { Write-Log "mpv option $k=$($opts[$k]) isn't supported by this mpv.net version; skipped." }
        }
        $rc = $m.Initialize()
        if ($rc -lt 0) { $m.Dispose(); throw ("mpv_initialize failed: " + [IdealVE.Mpv]::ErrorString($rc)) }
        [void]$m.RequestLog('error')
        foreach ($key in 'q', 'Q') { [void]$m.Command('keybind', $key, 'ignore') }   # don't let q quit the embedded core
        $script:Mpv = $m
        return $true
    } catch {
        Write-Log "Embedded preview unavailable: $($_.Exception.Message)"
        return $false
    }
}

function Get-PreviewVf([string]$path) {
    $vf = Get-FilterChain -Exposure ([math]::Round($sldEv.Value, 1)) -LutPath (Get-CurrentLut) -IsFull (Get-IsFullCached $path) -Preview
    if ($vf.Count) { return 'lavfi=[' + ($vf -join ',') + ']' }
    return ''
}

function Update-Preview([switch]$Reload) {
    if (-not ($script:Mpv -and $script:Mpv.IsAlive -and $script:PreviewPath)) { return }
    $vf = Get-PreviewVf $script:PreviewPath
    $rc = $script:Mpv.SetProperty('vf', $vf)
    if ($rc -lt 0) { Write-Log ("Preview filter error: " + [IdealVE.Mpv]::ErrorString($rc)) }

    $a = ConvertTo-Seconds $txtStart.Text; if ($null -ne $a -and [double]::IsNaN($a)) { $a = $null }
    $b = ConvertTo-Seconds $txtEnd.Text;   if ($null -ne $b -and [double]::IsNaN($b)) { $b = $null }
    if ($null -ne $a -and $null -ne $b -and $b -le $a) { $b = $null }
    [void]$script:Mpv.SetProperty('ab-loop-a', $(if ($null -ne $a) { $a.ToString($inv) } else { 'no' }))
    [void]$script:Mpv.SetProperty('ab-loop-b', $(if ($null -ne $b) { $b.ToString($inv) } else { 'no' }))

    if ($Reload) {
        [void]$script:Mpv.SetProperty('start', $(if ($null -ne $a) { $a.ToString($inv) } else { 'none' }))
        [void]$script:Mpv.Command('loadfile', $script:PreviewPath)
        [void]$script:Mpv.SetProperty('pause', 'no')
        $txtPauseIcon.Text = [string][char]0xE769
    } elseif ($null -ne $a) {
        $pos = $script:Mpv.GetProperty('time-pos')
        $cur = 0.0
        if ($pos -and [double]::TryParse($pos, [System.Globalization.NumberStyles]::Float, $inv, [ref]$cur)) {
            if ($cur -lt $a -or ($null -ne $b -and $cur -gt $b)) { [void]$script:Mpv.Command('seek', $a.ToString($inv), 'absolute') }
        }
    }
}

function Start-Preview {
    $item = Get-PreviewTarget
    if (-not $item) { Write-Log 'Add a clip to preview.'; return }
    Show-Video $true
    if (-not (Initialize-Mpv)) { Show-Video $false; Open-ExternalPreview $item; return }
    $script:PreviewPath = $item.Path
    $txtNowPlaying.Text = $item.Name
    Update-Preview -Reload
}

function Stop-Preview {
    if ($script:Mpv -and $script:Mpv.IsAlive) { [void]$script:Mpv.Command('stop') }
    $script:PreviewPath = $null
    Show-Video $false
}

function Open-ExternalPreview($item) {
    $mpv = Join-Path $MpvNetDir 'mpvnet.exe'
    if (-not (Test-Path -LiteralPath $mpv)) { Write-Log "mpv.net not found at $mpv"; return }
    if (-not $item) { Write-Log 'Add a clip to preview.'; return }
    $vf = Get-FilterChain -Exposure ([math]::Round($sldEv.Value, 1)) -LutPath (Get-CurrentLut) -IsFull (Get-IsFullCached $item.Path) -Preview
    $mpvArgs = @("--loop-file=inf")
    foreach ($k in $MpvTuning.Keys) { $mpvArgs += "--$k=$(if ($k -eq 'gpu-api') { $script:MpvGpuApi } else { $MpvTuning[$k] })" }
    $mpvArgs += "--title=Preview - $($item.Name)"
    if ($vf.Count -gt 0) { $mpvArgs += "--vf=lavfi=[" + ($vf -join ",") + "]" }
    $mpvArgs += $item.Path
    try {
        Start-Process -FilePath $mpv -ArgumentList (($mpvArgs | ForEach-Object { Quote-Arg $_ }) -join ' ')
        Write-Log "Opened $($item.Name) in mpv.net."
    } catch { Write-Log "Failed to launch mpv.net: $($_.Exception.Message)" }
}

# No usable Vulkan on this PC: switch the preview to Direct3D 11 (once) and restart it
function Switch-PreviewToD3D11 {
    $resume = $script:PreviewPath
    $script:MpvGpuApi = 'd3d11'
    Write-Log 'Vulkan is not available for the preview; switching to Direct3D 11.'
    $script:Mpv.Dispose(); $script:Mpv = $null; $script:PreviewPath = $null
    if ($resume) { Start-Preview }
}

function Read-MpvEvents {
    for ($i = 0; $i -lt 50; $i++) {
        if (-not ($script:Mpv -and $script:Mpv.IsAlive)) { return }
        $e = $script:Mpv.Poll()
        if ($null -eq $e) { return }
        if ($e.Id -eq 1) {
            $script:Mpv.Dispose(); $script:Mpv = $null; $script:PreviewPath = $null
            Show-Video $false
            Write-Log 'Preview player closed.'
            return
        }
        elseif ($e.Id -eq 2 -and $script:MpvGpuApi -eq 'vulkan' -and $e.Text -match 'Error opening/initializing the selected video_out|Failed initializing any suitable GPU context|Failed (to )?creat\w* (a )?Vulkan|vkCreate\w+ failed') {
            Switch-PreviewToD3D11
            return
        }
        elseif ($e.Id -eq 7 -and $e.Reason -eq 4 -and $script:MpvGpuApi -eq 'vulkan' -and $script:Mpv.GetProperty('vo-configured') -ne 'yes') {
            # Playback failed before any video output started: almost always the Vulkan renderer
            Switch-PreviewToD3D11
            return
        }
        elseif ($e.Id -eq 2) {
            # skip mpv probing hardware decoders that this GPU can't use; it falls back on its own
            if ($e.Text -notmatch 'hwaccel|hwdec|cuvid|d3d11va|dxva2|vulkan|AVHWDeviceContext|vaapi|qsv') { Write-Log ("[mpv] " + $e.Text) }
        }
        elseif ($e.Id -eq 7 -and $e.Reason -eq 4) { Write-Log ("Preview failed: " + [IdealVE.Mpv]::ErrorString($e.Error)) }
    }
}

# Debounce live preview updates while the slider is dragged
$previewDebounce = New-Object System.Windows.Threading.DispatcherTimer
$previewDebounce.Interval = [TimeSpan]::FromMilliseconds(150)
$previewDebounce.Add_Tick({ $previewDebounce.Stop(); Update-Preview })
function Request-PreviewUpdate { if ($script:PreviewPath) { $previewDebounce.Stop(); $previewDebounce.Start() } }

# ========== Conversion run ==========
# "04:30", "4:30", "4.30", "0430", "16:45", "4:30 pm", "4pm" -> time of day; $null if not a time
function ConvertTo-TimeOfDay([string]$text) {
    $s = ("$text".Trim().ToLowerInvariant() -replace '\s+', '') -replace '\.', ':'
    if ($s -notmatch '^(\d{1,2})(?::?(\d{2}))?(am|pm|a|p)?$') { return $null }
    $h = [int]$matches[1]; $m = if ($matches[2]) { [int]$matches[2] } else { 0 }; $ap = $matches[3]
    if ($ap) {
        if ($h -lt 1 -or $h -gt 12) { return $null }
        if ($ap -like 'p*' -and $h -lt 12) { $h += 12 }
        if ($ap -like 'a*' -and $h -eq 12) { $h = 0 }
    }
    if ($h -gt 23 -or $m -gt 59) { return $null }
    return New-TimeSpan -Hours $h -Minutes $m
}

# Next occurrence of a local time of day in this PC's time zone, returned in UTC so the countdown stays right
# across daylight-saving changes. A time skipped by the spring-forward gap starts just after the gap.
function Get-NextStartUtc([TimeSpan]$timeOfDay, [DateTime]$nowUtc = [DateTime]::UtcNow) {
    $tz = [TimeZoneInfo]::Local
    $nowLocal = [TimeZoneInfo]::ConvertTimeFromUtc($nowUtc, $tz)
    foreach ($day in 0, 1, 2) {
        $local = [DateTime]::SpecifyKind($nowLocal.Date.AddDays($day).Add($timeOfDay), [DateTimeKind]::Unspecified)
        if ($tz.IsInvalidTime($local)) { $local = $local.AddHours(1) }
        $utc = [TimeZoneInfo]::ConvertTimeToUtc($local, $tz)
        if ($utc -gt $nowUtc) { return $utc }
    }
}

function Format-LocalStart([DateTime]$utc, [switch]$NoZone) {
    $tz = [TimeZoneInfo]::Local
    $local = [TimeZoneInfo]::ConvertTimeFromUtc($utc, $tz)
    $zone = if ($tz.IsDaylightSavingTime($local)) { $tz.DaylightName } else { $tz.StandardName }
    if ($NoZone) { return "{0} {1}" -f $local.ToString('ddd'), $local.ToShortTimeString() }
    return "{0} {1} {2}" -f $local.ToString('ddd'), $local.ToShortTimeString(), $zone
}

function Format-Countdown([TimeSpan]$span) {
    if ($span.TotalSeconds -lt 0) { $span = [TimeSpan]::Zero }
    return "{0}:{1:mm\:ss}" -f [int][math]::Floor($span.TotalHours), $span
}

function Update-ScheduleUi {
    $later = $cmbStart.SelectedIndex -eq 1
    $pnlSchedule.Visibility = if ($later) { 'Visible' } else { 'Collapsed' }
    if (-not $later) { return }
    $tod = ConvertTo-TimeOfDay $txtStartTime.Text
    if ($null -eq $tod) { $txtScheduleHint.Text = 'Enter a time, e.g. 04:30 or 4:30 pm.'; return }
    $utc = Get-NextStartUtc $tod
    $left = $utc - [DateTime]::UtcNow
    $in = if ($left.TotalMinutes -lt 1) { 'in under a minute' } elseif ($left.TotalHours -lt 1) { "in {0} min" -f [int][math]::Ceiling($left.TotalMinutes) } else { "in {0} h {1} min" -f [int][math]::Floor($left.TotalHours), $left.Minutes }
    $txtScheduleHint.Text = "Starts {0}, {1}" -f (Format-LocalStart $utc), $in
}

function Set-RunState([string]$state) {
    $script:RunState = $state
    switch ($state) {
        'idle'      { $btnStart.IsEnabled = $true;  $txtStartLabel.Text = 'Start';      $btnCancel.IsEnabled = $false; $cmbStart.IsEnabled = $true; $txtStartTime.IsEnabled = $true }
        'scheduled' { $btnStart.IsEnabled = $true;  $txtStartLabel.Text = 'Start now';  $btnCancel.IsEnabled = $true;  $cmbStart.IsEnabled = $false; $txtStartTime.IsEnabled = $false }
        'running'   { $btnStart.IsEnabled = $false; $txtStartLabel.Text = 'Converting'; $btnCancel.IsEnabled = $true;  $cmbStart.IsEnabled = $false; $txtStartTime.IsEnabled = $false }
        'analysing' { $btnStart.IsEnabled = $false; $txtStartLabel.Text = 'Start';      $btnCancel.IsEnabled = $true;  $cmbStart.IsEnabled = $false; $txtStartTime.IsEnabled = $false }
    }
    Update-QueueState
}

# Snapshot and validate settings for the worker; $null (after telling the user) when something is wrong
function Get-RunOptions([switch]$Analysis) {
    foreach ($tool in 'ffmpeg', 'ffprobe', 'exiftool') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Show-Warning "$tool.exe was not found in PATH."; return $null }
    }
    $o = @{}
    $o.QualityTarget = Get-QualityTarget
    $o.LookKey = Get-LookKey
    $o.AutoCrf = [bool]$chkAutoCrf.IsChecked
    $o.AutoGrain = [bool]$chkAutoGrain.IsChecked

    $o.Codec = Get-Codec
    $o.CodecName = if ($o.Codec -eq 'av1') { 'AV1' } else { 'HEVC' }
    $o.Ext = Get-OutputExt
    $maxCrf = if ($o.Codec -eq 'av1') { 63 } else { 51 }
    $crf = 0
    if (-not [int]::TryParse($txtCrf.Text.Trim(), [ref]$crf) -or $crf -lt 0 -or $crf -gt $maxCrf) {
        if (-not $o.AutoCrf -and -not $o.QualityTarget) { Show-Warning "CRF must be a whole number from 0 to $maxCrf for $($o.CodecName)."; return $null }
        $crf = if ($o.Codec -eq 'av1') { ConvertTo-Av1Crf 21 } else { 21 }
    }
    $o.Crf = $crf
    $o.Grain = [math]::Max(0, $cmbGrain.SelectedIndex)

    $o.VbrEnabled = [bool]$chkVbr.IsChecked
    $rate = 0.0
    if ($o.VbrEnabled -and -not $o.QualityTarget -and (-not [double]::TryParse($txtMaxRate.Text.Trim(), [System.Globalization.NumberStyles]::Float, $inv, [ref]$rate) -or $rate -le 0)) {
        Show-Warning 'Max rate must be a positive number of Mbps.'; return $null
    }
    $o.MaxRate = $rate

    $o.Exposure = [math]::Round($sldEv.Value, 1)
    $o.LutPath = ''
    if ($chkLut.IsChecked) {
        if (-not ($script:LutPath -and (Test-Path -LiteralPath $script:LutPath))) { Show-Warning 'Choose a LUT file, or turn off Apply LUT.'; return $null }
        $o.LutPath = $script:LutPath
    }

    $o.TrimStart = ConvertTo-Seconds $txtStart.Text
    $o.TrimEnd = ConvertTo-Seconds $txtEnd.Text
    if (($null -ne $o.TrimStart -and [double]::IsNaN($o.TrimStart)) -or ($null -ne $o.TrimEnd -and [double]::IsNaN($o.TrimEnd))) {
        Show-Warning 'Trim times must be seconds (90) or mm:ss (1:30).'; return $null
    }
    if ($null -ne $o.TrimStart -and $null -ne $o.TrimEnd -and $o.TrimEnd -le $o.TrimStart) { Show-Warning 'Trim end must be after the start.'; return $null }

    if ($Analysis) { return $o }   # analysis only needs encoding + look settings

    $o.OutputMode = Get-OutputMode
    $o.OutputFolder = $txtOutFolder.Text.Trim()
    if ($o.OutputMode -eq 'custom') {
        if (-not $o.OutputFolder) { Show-Warning 'Choose an output folder.'; return $null }
        if (-not [IO.Path]::IsPathRooted($o.OutputFolder) -or $o.OutputFolder.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) {
            Show-Warning 'The output folder must be a full path, e.g. D:\Exports.'; return $null
        }
    }
    $o.Subfolder = $txtSubfolder.Text.Trim().Trim('\', '/')
    if ($o.Subfolder) {
        $bad = [IO.Path]::GetInvalidFileNameChars()
        foreach ($seg in ($o.Subfolder -split '[\\/]')) {
            if (-not $seg -or $seg -eq '..' -or $seg.IndexOfAny($bad) -ge 0) { Show-Warning "Subfolder '$($o.Subfolder)' is not a valid folder name."; return $null }
        }
    }

    $o.CsvEnabled = [bool]$chkCsv.IsChecked
    $o.CsvPath = $script:CsvPath
    return $o
}

function Start-Run {
    if ($script:Worker) { return }
    $opt = Get-RunOptions
    if (-not $opt) { Set-RunState 'idle'; return }
    $pending = @($script:Items | Where-Object { $_.StatusKey -ne 'done' })
    if ($pending.Count -eq 0) { $pending = @($script:Items) }   # everything done -> re-run the lot
    if ($pending.Count -eq 0) { Write-Log 'The queue is empty.'; Set-RunState 'idle'; return }

    foreach ($it in $pending) { $it.Status = 'Waiting'; $it.StatusKey = 'waiting'; $it.Progress = 0; $it.Detail = $it.Info }
    $opt.Overrides = @{}
    foreach ($it in $pending) { if ($script:ClipOverrides.ContainsKey($it.Path)) { $opt.Overrides[$it.Path] = $script:ClipOverrides[$it.Path] } }
    Save-Settings
    Start-Worker $WorkerScript @($pending | ForEach-Object { $_.Path }) $opt

    $txtOverall.Text = "Converting $($pending.Count) clip(s)"
    Set-RunState 'running'
    Write-Log "Started: $($pending.Count) clip(s)."
}

# Run a worker script in its own runspace; it reports back through $script:Sync.Queue
function Start-Worker([scriptblock]$body, [string[]]$jobs, [hashtable]$opt) {
    $script:Sync.Cancel = $false
    $script:Sync.Proc = $null
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($body.ToString()).AddArgument($script:Sync).AddArgument($jobs).AddArgument($opt).AddArgument($CoreScript.ToString())
    $script:Worker = $ps
    $script:WorkerRs = $rs
    $script:WorkerHandle = $ps.BeginInvoke()
    $prgOverall.Value = 0
    $txtEta.Text = ''
}

function Start-Analysis([switch]$All) {
    if ($script:Worker -or $script:RunState -ne 'idle') { return }
    # Each clip is analysed on its own: the selected clips, or the whole queue (-All, or when nothing is selected)
    $targets = if ($All) { @($script:Items) } else { @($lstQueue.SelectedItems) }
    if ($targets.Count -eq 0) { $targets = @($script:Items) }
    if ($targets.Count -eq 0) { Show-Warning 'Add some clips first.'; return }
    $vmafOk = (Invoke-Hidden 'ffmpeg' @('-hide_banner', '-filters')) -match '\blibvmaf\b'
    if (-not $vmafOk) { Show-Warning 'Your ffmpeg build has no libvmaf filter, which the analysis needs. The gyan.dev "full" build includes it.'; return }
    $opt = Get-RunOptions -Analysis
    if (-not $opt) { return }
    $opt.TargetVmaf = @(93, 95, 97)[[math]::Max(0, $cmbTarget.SelectedIndex)]

    $script:AnaItems.Clear()
    $script:AnaResults = @{}
    $script:AnaSuggest = $null
    $bdrAnaSummary.Visibility = 'Collapsed'
    foreach ($t in $targets) {
        $a = New-Object IdealVE.QueueItem
        $a.Name = $t.Name; $a.Path = $t.Path; $a.Status = 'Waiting'; $a.StatusKey = 'waiting'; $a.Detail = $t.Info
        $script:AnaItems.Add($a)
    }
    Start-Worker $AnalyzeScript @($targets | ForEach-Object { $_.Path }) $opt
    $txtOverall.Text = "Analysing $($targets.Count) clip(s)"
    Set-RunState 'analysing'
    Write-Log ("Analysis started: {0} clip(s), target VMAF {1}." -f $targets.Count, $opt.TargetVmaf)
}

function Find-AnaItem([string]$path) {
    foreach ($it in $script:AnaItems) { if ($it.Path -eq $path) { return $it } }
    return $null
}

function Stop-Run {
    $script:Sync.Cancel = $true
    $p = $script:Sync.Proc
    if ($p) { try { if (-not $p.HasExited) { $p.Kill() } } catch {} }
}

function Receive-WorkerMessages {
    $m = $null
    while ($script:Sync.Queue.TryDequeue([ref]$m)) {
        switch ($m.T) {
            'log' { Write-Log $m.Text }
            'item' {
                $it = Find-QueueItem $m.Path
                if ($it) {
                    $it.Status = $m.Status
                    $it.StatusKey = $m.Key
                    if ($m.ContainsKey('Progress')) { $it.Progress = $m.Progress }
                    if ($m.ContainsKey('Detail')) { $it.Detail = $m.Detail }
                }
            }
            'overall' { $prgOverall.Value = $m.Value; $txtOverall.Text = $m.Text; $txtEta.Text = $m.Eta }
            'aitem' {
                $it = Find-AnaItem $m.Path
                if ($it) {
                    $it.Status = $m.Status
                    $it.StatusKey = $m.Key
                    if ($m.ContainsKey('Progress')) { $it.Progress = $m.Progress }
                    if ($m.ContainsKey('Detail')) { $it.Detail = $m.Detail }
                }
            }
            'aresult' {
                $script:AnaResults[$m.Path] = @{ Crf = $m.Crf; Cap = $m.Cap; Grain = $m.Grain; Target = $m.Target; Key = $m.Key; CodecName = $m.CodecName; Met = $m.Met; Vmaf = $m.Vmaf }
            }
            'override' {
                $script:ClipOverrides[$m.Path] = @{ Crf = $m.Crf; Cap = $m.Cap; Grain = $m.Grain; Target = $m.Target; Key = $m.Key; CodecName = $m.CodecName; Met = $m.Met; Vmaf = $m.Vmaf }
                Update-OverrideNotes
            }
            'aend' {
                $txtOverall.Text = 'Analysis finished'
                $txtEta.Text = $(if ($m.Cancelled) { 'cancelled' } else { "$($m.Count) clip(s)" }) + " $dot " + $m.Elapsed.ToString('hh\:mm\:ss')
                if (-not $m.Cancelled) { $prgOverall.Value = 100 }
                if ($m.Count) {
                    $script:AnaSuggest = @{ Crf = [int]$m.Crf; Cap = [int]$m.Cap }
                    $txtAnaSummary.Text = if ($m.Count -gt 1) {
                        "Each clip has its own suggestion. Use them per clip, or apply CRF {0} with a {1} Mbps cap to everything (the most demanding clip's CRF and the largest cap)." -f $m.Crf, $m.Cap
                    } else { "Suggested: CRF {0} with a {1} Mbps cap. Use it for this clip only, or apply it to everything." -f $m.Crf, $m.Cap }
                    $btnAnaApply.Content = "Apply to all (CRF $($m.Crf), $($m.Cap) Mbps)"
                    $bdrAnaSummary.Visibility = 'Visible'
                }
                Write-Log ("Analysis finished{0}." -f $(if ($m.Count) { ": CRF $($m.Crf), cap $($m.Cap) Mbps" } else { '' }))
            }
            'end' {
                $summary = "{0} converted" -f $m.Ok
                if ($m.Failed) { $summary += ", $($m.Failed) failed" }
                if ($m.Cancelled) { $summary += ", cancelled" }
                $txtOverall.Text = 'Finished'
                $txtEta.Text = "$summary $dot " + $m.Elapsed.ToString('hh\:mm\:ss')
                if (-not $m.Cancelled) { $prgOverall.Value = 100 }
                Write-Log "Finished: $summary."
            }
        }
    }
}

function Complete-Run {
    Receive-WorkerMessages
    try { [void]$script:Worker.EndInvoke($script:WorkerHandle) } catch { Write-Log "Worker error: $($_.Exception.Message)" }
    foreach ($err in $script:Worker.Streams.Error) { Write-Log "Worker error: $err" }
    try { $script:Worker.Dispose(); $script:WorkerRs.Dispose() } catch {}
    $script:Worker = $null; $script:WorkerRs = $null; $script:WorkerHandle = $null
    foreach ($it in $script:Items) {
        if ($it.StatusKey -eq 'waiting' -or $it.StatusKey -eq 'active') { $it.Status = 'Queued'; $it.StatusKey = 'queued'; $it.Progress = 0; $it.Detail = $it.Info }
    }
    foreach ($it in $script:AnaItems) {
        if ($it.StatusKey -eq 'waiting' -or $it.StatusKey -eq 'active') { $it.Status = 'Not analysed'; $it.StatusKey = 'cancelled'; $it.Progress = 0 }
    }
    Set-RunState 'idle'
}

# ========== Pump: worker messages, mpv events, schedule, CPU ==========
$pump = New-Object System.Windows.Threading.DispatcherTimer
$pump.Interval = [TimeSpan]::FromMilliseconds(100)
$pump.Add_Tick({
    try {
        Receive-WorkerMessages
        if ($script:Worker -and $script:WorkerHandle.IsCompleted) { Complete-Run }
        Read-MpvEvents

        $script:Tick++
        if ($script:Tick % 10 -eq 0) {
            if ($script:Cpu) { try { $txtCpu.Text = 'CPU ' + [math]::Round($script:Cpu.NextValue()) + '%' } catch {} }
            if ($script:RunState -eq 'scheduled') {
                $rem = $script:ScheduledAt - [DateTime]::UtcNow
                if ($rem.TotalSeconds -le 0) { Start-Run }
                else { $txtOverall.Text = 'Scheduled for ' + (Format-LocalStart $script:ScheduledAt -NoZone); $txtEta.Text = 'Starts in ' + (Format-Countdown $rem) }
            } elseif ($script:RunState -eq 'idle' -and $cmbStart.SelectedIndex -eq 1) {
                Update-ScheduleUi   # keep "in 5 h 32 min" current
            }
        }
    } catch { Write-Log "UI error: $($_.Exception.Message)" }
})

# ========== Events ==========
$btnAdd.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Video clips (*.mov;*.mp4)|*.mov;*.mp4|All files (*.*)|*.*'
    $dlg.Multiselect = $true
    $dlg.Title = 'Add clips'
    if ($dlg.ShowDialog($window)) { Add-QueueFiles $dlg.FileNames }
})

$btnRemove.Add_Click({
    foreach ($it in @($lstQueue.SelectedItems)) { [void]$script:Items.Remove($it); [void]$script:ClipOverrides.Remove($it.Path) }
    Update-QueueState
})

$btnClear.Add_Click({
    $script:Items.Clear()
    $script:ClipOverrides.Clear()
    Write-Log 'Queue cleared.'
    Update-QueueState
})

$lstQueue.Add_SelectionChanged({ Update-QueueState })
$lstQueue.Add_MouseDoubleClick({ param($sender, $e)
    if ($e.OriginalSource -is [System.Windows.FrameworkElement] -and $e.OriginalSource.DataContext -is [IdealVE.QueueItem]) { Start-Preview }
})
$lstQueue.Add_KeyDown({ param($sender, $e)
    if ($e.Key -eq 'Delete' -and $btnRemove.IsEnabled) { foreach ($it in @($lstQueue.SelectedItems)) { [void]$script:Items.Remove($it); [void]$script:ClipOverrides.Remove($it.Path) }; Update-QueueState; $e.Handled = $true }
    elseif ($e.Key -eq 'Return') { Start-Preview; $e.Handled = $true }
})

$window.Add_PreviewDragOver({ param($sender, $e)
    $e.Effects = if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop) -and $script:RunState -ne 'running') { 'Copy' } else { 'None' }
    $e.Handled = $true
})
$window.Add_PreviewDrop({ param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { Add-QueueFiles ([string[]]$e.Data.GetData([System.Windows.DataFormats]::FileDrop)) }
    $e.Handled = $true
})

# Look
$btnLut.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = '3D LUT (*.cube)|*.cube'
    $dlg.Title = 'Choose a LUT'
    if ($script:LutPath) { $dlg.InitialDirectory = [IO.Path]::GetDirectoryName($script:LutPath) }
    if ($dlg.ShowDialog($window)) {
        Set-LutPath $dlg.FileName
        Update-OverrideNotes
        $chkLut.IsChecked = $true
        Write-Log "LUT: $($dlg.FileName)"
        Request-PreviewUpdate
    }
})
$chkLut.Add_Checked({ Request-PreviewUpdate; Update-OverrideNotes })
$chkLut.Add_Unchecked({ Request-PreviewUpdate; Update-OverrideNotes })
$cmbGrain.Add_SelectionChanged({ Update-OverrideNotes })
$cmbQualityTarget.Add_SelectionChanged({ Update-Enablement })
$sldEv.Add_ValueChanged({ Update-EvLabel; Request-PreviewUpdate; Update-OverrideNotes })
$sldEv.Add_MouseDoubleClick({ $sldEv.Value = 0 })
$btnEvReset.Add_Click({ $sldEv.Value = 0 })

# Codec switch: park the CRF typed for the old codec, restore the new codec's
$cmbCodec.Add_SelectionChanged({
    $new = Get-Codec
    if (-not $script:Loading -and $script:LastCodec -ne $new) {
        $script:CrfByCodec[$script:LastCodec] = $txtCrf.Text
        $txtCrf.Text = $script:CrfByCodec[$new]
    }
    $script:LastCodec = $new
    Update-CodecUi
    Update-OutputPreview
    Update-OverrideNotes
})

# Encoding + output toggles
foreach ($c in @($chkAutoCrf, $chkAutoGrain, $chkVbr, $chkCsv, $rbSource, $rbCustom)) {
    $c.Add_Checked({ Update-Enablement })
    $c.Add_Unchecked({ Update-Enablement })
}
$txtOutFolder.Add_TextChanged({ Update-OutputPreview })
$txtSubfolder.Add_TextChanged({ Update-OutputPreview })
$btnOutFolder.Add_Click({
    $owner = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    $picked = [IdealVE.FolderPicker]::Show($owner, 'Choose output folder', $txtOutFolder.Text.Trim())
    if ($picked) { $txtOutFolder.Text = $picked }
})
$btnCsv.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = [IO.Path]::GetFileName($script:CsvPath)
    $dlg.InitialDirectory = [IO.Path]::GetDirectoryName($script:CsvPath)
    if ($dlg.ShowDialog($window)) { $script:CsvPath = $dlg.FileName; $chkCsv.IsChecked = $true; Update-Enablement }
})

# Trim: re-apply the preview loop range when editing finishes
foreach ($t in @($txtStart, $txtEnd)) {
    $t.Add_LostKeyboardFocus({ Request-PreviewUpdate })
    $t.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Return') { Request-PreviewUpdate } })
}

# Preview transport
$btnPreview.Add_Click({ Start-Preview })
$btnStop.Add_Click({ Stop-Preview })
$btnPause.Add_Click({
    if (-not ($script:Mpv -and $script:Mpv.IsAlive)) { return }
    [void]$script:Mpv.Command('cycle', 'pause')
    $txtPauseIcon.Text = if ($script:Mpv.GetProperty('pause') -eq 'yes') { [string][char]0xE768 } else { [string][char]0xE769 }
})
$btnPopOut.Add_Click({ Open-ExternalPreview (Get-PreviewTarget) })

# Run
$btnStart.Add_Click({
    if ($script:RunState -eq 'scheduled') { Start-Run; return }
    if ($script:RunState -ne 'idle') { return }
    if ($script:Items.Count -eq 0) { Show-Warning 'Add some clips first.'; return }
    if ($cmbStart.SelectedIndex -ne 1) { Start-Run; return }
    $tod = ConvertTo-TimeOfDay $txtStartTime.Text
    if ($null -eq $tod) { Show-Warning 'Enter a start time, for example 04:30 or 4:30 pm.'; return }
    if (-not (Get-RunOptions)) { return }   # validate now rather than at the scheduled time
    $script:ScheduledAt = Get-NextStartUtc $tod
    Save-Settings
    Set-RunState 'scheduled'
    $txtOverall.Text = 'Scheduled for ' + (Format-LocalStart $script:ScheduledAt -NoZone)
    $txtEta.Text = 'Starts in ' + (Format-Countdown ($script:ScheduledAt - [DateTime]::UtcNow))
    Write-Log ("Queued to start at {0}." -f (Format-LocalStart $script:ScheduledAt))
})
$cmbStart.Add_SelectionChanged({ Update-ScheduleUi })
$txtStartTime.Add_TextChanged({ Update-ScheduleUi })
$btnCancel.Add_Click({
    if ($script:RunState -eq 'scheduled') {
        Set-RunState 'idle'
        $txtOverall.Text = 'Ready'; $txtEta.Text = ''
        Write-Log 'Scheduled start cancelled.'
    } elseif ($script:RunState -eq 'running' -or $script:RunState -eq 'analysing') {
        Stop-Run
        $btnCancel.IsEnabled = $false
        $txtOverall.Text = 'Cancelling'
        Write-Log $(if ($script:RunState -eq 'analysing') { 'Cancelling the analysis...' } else { 'Cancelling the queue...' })
    }
})

# Analysis
$btnAnalyze.Add_Click({ Start-Analysis })
$btnAnalyzeMore.Add_Click({
    $menu = $btnAnalyzeMore.ContextMenu
    $menu.PlacementTarget = $btnAnalyzeMore
    $menu.IsOpen = $true
})
$btnAnalyzeMore.ContextMenu.Items[0].Add_Click({ Start-Analysis -All })
$btnAnalyzeMore.ContextMenu.Items[1].Add_Click({ Start-Analysis })
$btnAnaPerClip.Add_Click({
    $n = 0
    foreach ($path in @($script:AnaResults.Keys)) {
        if (Find-QueueItem $path) { $script:ClipOverrides[$path] = $script:AnaResults[$path]; $n++ }
    }
    Update-OverrideNotes
    Write-Log "Per-clip settings applied to $n clip(s); each will encode with its own CRF and cap."
    $tabMain.SelectedItem = $tabQueue
})
$btnAnaApply.Add_Click({
    if (-not $script:AnaSuggest) { return }
    # One setting for everything: drop the per-clip results for the analysed clips and the quality target
    foreach ($path in @($script:AnaResults.Keys)) { [void]$script:ClipOverrides.Remove($path) }
    $cmbQualityTarget.SelectedIndex = 0
    $chkAutoCrf.IsChecked = $false
    $txtCrf.Text = [string]$script:AnaSuggest.Crf
    $chkVbr.IsChecked = $true
    $txtMaxRate.Text = [string]$script:AnaSuggest.Cap
    Update-Enablement
    Save-Settings
    Write-Log "Applied analysis suggestion: CRF $($script:AnaSuggest.Crf), $($script:AnaSuggest.Cap) Mbps cap."
})

# ========== Window lifecycle ==========
$window.Add_SourceInitialized({
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    [void][IdealVE.Native]::SetWindowAttribute($hwnd, 20, [int](-not $IsLight))   # dark title bar in dark mode
    # Mica backdrop (Windows 11 22H2+); silently keeps the solid background elsewhere
    if ([IdealVE.Native]::SetWindowAttribute($hwnd, 38, 2) -eq 0) {
        $window.Background = [System.Windows.Media.Brushes]::Transparent
        [System.Windows.Interop.HwndSource]::FromHwnd($hwnd).CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
        [void][IdealVE.Native]::ExtendFrameIntoClientArea($hwnd)
    }
})

$window.Add_ContentRendered({
    try { $script:Cpu = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total'); [void]$script:Cpu.NextValue() } catch { $txtCpu.Text = '' }
})

$window.Add_Closing({ param($sender, $e)
    if ($script:RunState -eq 'running' -or $script:RunState -eq 'analysing') {
        $r = [System.Windows.MessageBox]::Show($window, 'A conversion or analysis is running. Stop it and quit?', 'Ideal Video Encoder', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        Stop-Run
    }
    Save-Settings
    $pump.Stop()
    if ($script:Mpv) { $script:Mpv.Dispose(); $script:Mpv = $null }
})

$window.Dispatcher.Add_UnhandledException({ param($sender, $e)
    Write-Log "Unexpected error: $($e.Exception.Message)"
    $e.Handled = $true
})

# ========== Start ==========
Import-Settings
Update-EvLabel
Update-Enablement
Set-RunState 'idle'
if ($Paths) { Add-QueueFiles $Paths }
$pump.Start()
[void]$window.ShowDialog()

if ($script:Worker) { try { $script:Worker.Stop() } catch {} }
