using System;
using System.Reflection;
using Microsoft.Win32;
using Drawing = System.Drawing;
using WinForms = System.Windows.Forms;

namespace BoringNotch
{
    /// <summary>The icon by the clock: the only way to quit, as the notch itself has no menu.</summary>
    internal sealed class Tray : IDisposable
    {
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValue = "BoringNotch";

        private readonly WinForms.NotifyIcon _icon;
        private readonly Drawing.Icon _image;

        public Tray(Action quit)
        {
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("BoringNotch.ico"))
            {
                _image = new Drawing.Icon(stream, WinForms.SystemInformation.SmallIconSize);
            }

            var autostart = new WinForms.ToolStripMenuItem("Mit Windows starten") { Checked = StartsWithWindows, CheckOnClick = true };
            autostart.Click += (sender, e) =>
            {
                StartsWithWindows = autostart.Checked;
                autostart.Checked = StartsWithWindows;
            };

            var menu = new WinForms.ContextMenuStrip();
            menu.Items.Add(new WinForms.ToolStripMenuItem("Boring Notch") { Enabled = false });
            menu.Items.Add(new WinForms.ToolStripSeparator());
            menu.Items.Add(autostart);
            menu.Items.Add("Beenden", null, (sender, e) => quit());

            _icon = new WinForms.NotifyIcon
            {
                Icon = _image,
                Text = "Boring Notch",
                ContextMenuStrip = menu,
                Visible = true,
            };
        }

        private static bool StartsWithWindows
        {
            get
            {
                try
                {
                    using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKey, false))
                    {
                        return key?.GetValue(RunValue) != null;
                    }
                }
                catch (Exception e) when (e is System.Security.SecurityException || e is UnauthorizedAccessException)
                {
                    return false;
                }
            }
            set
            {
                try
                {
                    using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKey))
                    {
                        if (value)
                        {
                            key.SetValue(RunValue, "\"" + Assembly.GetExecutingAssembly().Location + "\"");
                        }
                        else
                        {
                            key.DeleteValue(RunValue, false);
                        }
                    }
                }
                catch (Exception e) when (e is System.Security.SecurityException || e is UnauthorizedAccessException)
                {
                    Log.Error(e);
                }
            }
        }

        public void Dispose()
        {
            // Or the icon stays by the clock until the mouse passes over it
            _icon.Visible = false;
            _icon.Dispose();
            _image.Dispose();
        }
    }
}
