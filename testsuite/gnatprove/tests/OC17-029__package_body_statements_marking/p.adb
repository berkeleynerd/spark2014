package body P is

begin
   pragma SPARK_Mode (Off);
   declare
      X     : aliased Integer;
      X_Ptr : access Integer := X'Access;
   begin
      X_Ptr.all := 0;
   end;
end;
