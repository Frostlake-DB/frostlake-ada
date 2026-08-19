--  The half of the suite that needs a live DatabaseHttpServer.  The main
--  program boots one from FROSTLAKE_CLASSPATH and passes its address; a
--  run without the classpath never gets here.

package Integration_Tests is

   procedure Run (Dsn_Base : String);
   --  Dsn_Base is "frostlake://127.0.0.1:<port>" — no database.

end Integration_Tests;
