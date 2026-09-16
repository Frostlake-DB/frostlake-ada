--  The whole test harness: counters and checks.  No framework — a failed
--  check prints and is tallied; the main program turns the tally into the
--  exit status.

package Test_Support is

   procedure Note (Message : String);
   --  Progress line, flushed immediately.

   procedure Check (Condition : Boolean; Label : String);

   procedure Check_Equal (Got : String; Want : String; Label : String);

   procedure Check_Equal
     (Got   : Long_Long_Integer;
      Want  : Long_Long_Integer;
      Label : String);

   procedure Record_Failure (Label : String);
   --  For hand-rolled patterns the two Checks do not cover — an expected
   --  exception that did not arrive, an unexpected one that did.

   procedure Skip (Label : String; Why : String);
   --  A check this engine cannot answer.  The driver supports engines older
   --  than the behaviour some checks look for; counting one of those as a
   --  pass would claim an engine had been checked for something it never
   --  reports, so it is tallied apart and printed with its reason.

   function Passed return Natural;
   function Failed return Natural;
   function Skipped return Natural;

end Test_Support;
