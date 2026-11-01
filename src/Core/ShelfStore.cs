using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace BoringNotch.Core
{
    /// <summary>
    /// The files on the shelf. Only their paths are kept, one per line: the files stay where they are.
    /// </summary>
    public sealed class ShelfStore
    {
        private readonly string _file;
        private readonly Func<string, bool> _exists;
        private readonly List<string> _paths = new List<string>();

        public ShelfStore(string file, Func<string, bool> exists = null)
        {
            _file = file;
            _exists = exists ?? StillThereOrUnknown;
        }

        /// <summary>
        /// Only a file really gone comes off the shelf. On a USB stick that's unplugged it can't be told, and it's
        /// back with the stick. A network share isn't asked at all, as an offline one would freeze the notch for its timeout.
        /// </summary>
        public static bool StillThereOrUnknown(string path)
        {
            try
            {
                string root = Path.GetPathRoot(path);
                if (string.IsNullOrEmpty(root) || root.StartsWith(@"\\", StringComparison.Ordinal)) return true;
                if (!Directory.Exists(root)) return true;
                if (root.Length > 1 && new DriveInfo(root).DriveType == DriveType.Network) return true;
                return File.Exists(path) || Directory.Exists(path);
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException || e is ArgumentException)
            {
                return true;
            }
        }

        public IReadOnlyList<string> Paths => _paths;

        public bool IsEmpty => _paths.Count == 0;

        public void Load()
        {
            _paths.Clear();
            string[] lines;
            try
            {
                if (!File.Exists(_file)) return;
                lines = File.ReadAllLines(_file, Encoding.UTF8);
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
            {
                return;
            }
            foreach (string line in lines)
            {
                string path = line.Trim();
                if (path.Length > 0 && !Contains(path))
                {
                    _paths.Add(path);
                }
            }
        }

        /// <summary>False if it's on the shelf already.</summary>
        public bool Add(string path)
        {
            if (string.IsNullOrWhiteSpace(path) || Contains(path)) return false;
            _paths.Add(path);
            Save();
            return true;
        }

        public void Remove(string path)
        {
            if (_paths.RemoveAll(p => Same(p, path)) > 0)
            {
                Save();
            }
        }

        /// <summary>Takes off what was moved or deleted in the meantime. True if anything went.</summary>
        public bool CleanupMissing()
        {
            if (_paths.RemoveAll(p => !_exists(p)) == 0) return false;
            Save();
            return true;
        }

        private bool Contains(string path) => _paths.Any(p => Same(p, path));

        // Paths on Windows don't care about case
        private static bool Same(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

        private void Save()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_file));
                string temporary = _file + ".neu";
                File.WriteAllLines(temporary, _paths, new UTF8Encoding(false));
                if (File.Exists(_file))
                {
                    File.Delete(_file);
                }
                File.Move(temporary, _file);
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
            {
                // The shelf still works until the app quits, it just won't be there after a restart
            }
        }
    }
}
