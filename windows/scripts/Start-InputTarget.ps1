[CmdletBinding()]
param(
    [string]$LogPath,
    [ValidateRange(400, 4096)][int]$ClientWidth = 1100,
    [ValidateRange(300, 4096)][int]$ClientHeight = 800
)

$ErrorActionPreference = 'Stop'
if (-not $LogPath) {
    $LogPath = Join-Path $PSScriptRoot ('..\.local\build\logs\input-target-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.jsonl')
}
$LogPath = [IO.Path]::GetFullPath($LogPath)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null

# Invoke explicitly in a dedicated powershell.exe -NoProfile -STA process.
# This script owns only its form and JSONL log; it never launches another app.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Web.Extensions
if (-not ('Caelestia.InputTest.Target' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Web.Extensions -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace Caelestia.InputTest {
    public sealed class Target : Form {
        [DllImport("user32.dll")]
        private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

        private readonly StreamWriter log;
        private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();
        private readonly Label status = new Label();
        private readonly TextBox input = new TextBox();
        private readonly Stopwatch elapsed = Stopwatch.StartNew();
        private int clickCount, activationCount, keyDownCount, typedKeyCount;
        private int lastX = -1, lastY = -1;
        private long sequence;
        private bool isActive;

        private Target(string logPath, int clientWidth, int clientHeight) {
            // Append permits a caller to keep before/after observations in one
            // file. Run IDs distinguish sessions; each line is flushed at once.
            log = new StreamWriter(logPath, true, new UTF8Encoding(false));
            log.AutoFlush = true;
            Text = "Caelestia input test target";
            Name = "CaelestiaInputTestTarget";
            // Tool-window style keeps this test fixture outside the existing
            // tiler's ordinary application layout without changing its policy.
            FormBorderStyle = FormBorderStyle.SizableToolWindow;
            ShowInTaskbar = false;
            AutoScaleMode = AutoScaleMode.None;
            ClientSize = new Size(clientWidth, clientHeight);
            MinimumSize = new Size(420, 340);
            StartPosition = FormStartPosition.CenterScreen;
            KeyPreview = true;
            BackColor = Color.FromArgb(242, 245, 248);

            Label instructions = new Label();
            instructions.Name = "Instructions";
            instructions.Text = "Dedicated input target. Click this client area, type in the box, then open and dismiss the Caelestia drawer to test focus return.";
            instructions.SetBounds(24, 20, clientWidth - 48, 60);
            instructions.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;

            status.Name = "InputStatus";
            status.SetBounds(24, 92, clientWidth - 48, 150);
            status.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            status.Font = new Font(FontFamily.GenericMonospace, 12);
            status.AccessibleName = "Input counters and activation state";

            input.Name = "TypingTarget";
            input.AccessibleName = "Input test text box";
            input.Multiline = true;
            input.AcceptsReturn = true;
            input.AcceptsTab = true;
            input.ScrollBars = ScrollBars.Vertical;
            input.SetBounds(24, 260, clientWidth - 48, clientHeight - 284);
            input.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
            input.Font = new Font(FontFamily.GenericMonospace, 14);

            Controls.Add(instructions);
            Controls.Add(status);
            Controls.Add(input);
            TrackMouse(this);
            KeyDown += delegate(object sender, KeyEventArgs e) {
                keyDownCount++;
                UpdateStatus();
                Record("keyDown", new Dictionary<string, object> {
                    { "key", e.KeyCode.ToString() }, { "modifiers", e.Modifiers.ToString() }
                });
            };
            KeyPress += delegate(object sender, KeyPressEventArgs e) {
                typedKeyCount++;
                UpdateStatus();
                Record("keyPress", new Dictionary<string, object> {
                    { "character", e.KeyChar.ToString() }, { "characterCode", (int)e.KeyChar }
                });
            };
            Activated += delegate {
                isActive = true;
                activationCount++;
                UpdateStatus();
                Record("activated", null);
            };
            Deactivate += delegate {
                isActive = false;
                UpdateStatus();
                Record("deactivate", null);
            };
            Shown += delegate { input.Focus(); Record("shown", null); };
            FormClosed += delegate { Record("closed", null); };
            UpdateStatus();
            Record("created", new Dictionary<string, object> { { "logPath", logPath } });
        }

        private readonly string runId = Guid.NewGuid().ToString("N");

        private void TrackMouse(Control control) {
            control.MouseDown += delegate(object sender, MouseEventArgs e) {
                Control source = (Control)sender;
                Point local = PointToClient(source.PointToScreen(e.Location));
                lastX = local.X;
                lastY = local.Y;
                clickCount++;
                UpdateStatus();
                Record("mouseDown", new Dictionary<string, object> {
                    { "button", e.Button.ToString() }, { "clicks", e.Clicks },
                    { "control", source.Name }, { "x", lastX }, { "y", lastY }
                });
            };
            foreach (Control child in control.Controls) TrackMouse(child);
        }

        private void UpdateStatus() {
            status.Text = String.Format(
                "Mouse down count: {0}\r\nLast mouse (client): {1}, {2}\r\nActivation count: {3}   Active: {4}\r\nKey down count: {5}   Typed key count (KeyPress): {6}\r\nPID: {7}",
                clickCount, lastX, lastY, activationCount, isActive,
                keyDownCount, typedKeyCount, Process.GetCurrentProcess().Id);
        }

        private void Record(string kind, Dictionary<string, object> detail) {
            Dictionary<string, object> entry = new Dictionary<string, object> {
                { "event", kind }, { "sequence", ++sequence }, { "runId", runId },
                { "timestampUtc", DateTime.UtcNow.ToString("o") },
                { "elapsedMilliseconds", elapsed.ElapsedMilliseconds },
                { "processId", Process.GetCurrentProcess().Id },
                { "clickCount", clickCount }, { "lastMouseX", lastX }, { "lastMouseY", lastY },
                { "activationCount", activationCount }, { "active", isActive },
                { "keyDownCount", keyDownCount }, { "typedKeyCount", typedKeyCount },
                { "clientWidth", ClientSize.Width }, { "clientHeight", ClientSize.Height },
                { "detail", detail }
            };
            log.WriteLine(serializer.Serialize(entry));
        }

        protected override void Dispose(bool disposing) {
            if (disposing) log.Dispose();
            base.Dispose(disposing);
        }

        [STAThread]
        public static void Run(string logPath, int clientWidth, int clientHeight) {
            // Per-monitor awareness keeps this window's client coordinates in
            // physical pixels, including when moved across different DPI.
            // Only this UI thread's context changes, and it is restored on exit.
            IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
            if (previous == IntPtr.Zero)
                throw new InvalidOperationException("Could not select per-monitor DPI awareness for the input target.");
            try {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using (Target target = new Target(logPath, clientWidth, clientHeight)) {
                    Application.Run(target);
                }
            } finally {
                SetThreadDpiAwarenessContext(previous);
            }
        }
    }
}
'@
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    throw 'Run this script in a dedicated powershell.exe -NoProfile -STA -File process.'
}
Write-Output "Input target PID: $PID; JSONL: $LogPath"
[Caelestia.InputTest.Target]::Run($LogPath, $ClientWidth, $ClientHeight)
