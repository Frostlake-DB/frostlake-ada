pragma Ada_2022;

--  A minimal HTTP/1.1 client over GNAT.Sockets — just enough for the
--  engine's API.  Every request opens its own connection and sends
--  Connection: close, which against DatabaseHttpServer is measurably
--  FASTER than keep-alive (a reused connection hits a delayed-ACK stall
--  of ~48 ms per statement versus ~0.8 ms for a fresh one) — do not
--  "optimise" this into a kept-alive session.  Public so the test suite
--  can point it at a loopback server; not otherwise part of the driver's
--  stable API.

package Frostlake.Http is

   type Reply is record
      Status  : Natural := 0;
      Content : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Post
     (Host         : String;
      Port         : Positive;
      Path         : String;
      Content      : String;
      Open_Timeout : Duration;
      Read_Timeout : Duration) return Reply;
   --  POST Content as application/json.  Raises Connection_Error when the
   --  host cannot be reached, times out, or answers unintelligibly.

   function Get
     (Host         : String;
      Port         : Positive;
      Path         : String;
      Open_Timeout : Duration;
      Read_Timeout : Duration) return Reply;

end Frostlake.Http;
