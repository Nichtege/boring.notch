using System;
using System.Collections.Generic;
using System.Data.OleDb;
using System.Globalization;
using System.Threading.Tasks;
using BoringNotch.Core;

namespace BoringNotch
{
    internal sealed class FileSearchOutcome
    {
        public IReadOnlyList<string> Paths = new string[0];
        /// <summary>The index couldn't be asked, usually because the Windows Search service is off.</summary>
        public bool Failed;
    }

    /// <summary>Asks the index that Windows Search keeps, and only reads from it.</summary>
    internal static class FileSearch
    {
        private const string Connection = "Provider=Search.CollatorDSO;Extended Properties='Application=Windows';";
        private const int TimeoutSeconds = 5;

        private static readonly object ReportGate = new object();
        private static string _lastProblem;

        public static Task<FileSearchOutcome> FindAsync(string query, int top)
        {
            return Task.Run(() => Find(query, top));
        }

        private static FileSearchOutcome Find(string query, int top)
        {
            try
            {
                string sql = FileQuery.Build(query, top);
                if (sql == null) return new FileSearchOutcome();

                var paths = new List<string>();
                using (var connection = new OleDbConnection(Connection))
                using (var command = new OleDbCommand(sql, connection) { CommandTimeout = TimeoutSeconds })
                {
                    connection.Open();
                    using (OleDbDataReader reader = command.ExecuteReader())
                    {
                        while (reader != null && reader.Read())
                        {
                            string path = reader.IsDBNull(0) ? null : FileQuery.PathFromUrl(reader.GetValue(0) as string);
                            if (path != null)
                            {
                                paths.Add(path);
                            }
                        }
                    }
                }
                return new FileSearchOutcome { Paths = paths };
            }
            catch (Exception e)
            {
                Report(e);
                return new FileSearchOutcome { Failed = true };
            }
        }

        /// <summary>
        /// Only the type and the code, as the provider's messages can quote the query. Once each, as a service
        /// that's off would otherwise fill the log with every key pressed.
        /// </summary>
        private static void Report(Exception e)
        {
            string problem = "Dateisuche: " + e.GetType().Name + " 0x" + e.HResult.ToString("X8", CultureInfo.InvariantCulture);
            lock (ReportGate)
            {
                if (problem == _lastProblem) return;
                _lastProblem = problem;
            }
            Log.Note(problem);
        }
    }
}
