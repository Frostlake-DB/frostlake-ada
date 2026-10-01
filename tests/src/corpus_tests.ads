--  The last step of the suite: the engine's testkit corpus, replayed
--  through the driver by bin/testkit_runner, the crate's second main, when
--  FL_CORPUS names frostlake's engine/src/test/resources/testkit.

package Corpus_Tests is

   procedure Run;
   --  Skipped when FL_CORPUS is unset or no engine is configured, and a
   --  failure when FL_CORPUS holds no suites/*.json or the runner reports
   --  a failed case.  The runner attaches to FROSTLAKE_URL, or else to a
   --  server of its own booted from FROSTLAKE_CLASSPATH, whose user.home is
   --  a fresh temporary directory so that no stage or setting of an earlier
   --  run is in its way.

end Corpus_Tests;
