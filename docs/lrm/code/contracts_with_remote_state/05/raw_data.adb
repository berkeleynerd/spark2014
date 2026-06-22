package body Raw_Data
--# own State is Last_Read, in In_Port;
is

   In_Port : Integer;
   -- Address clause would go here
   pragma Volatile (In_Port);

   Last_Read : Integer := 0;

   function Data_Is_Valid return Boolean
   --# global Last_Read;
   is
   begin
     return Last_Read /= 0 and Last_Read > -23 and Last_Read < 117;
   end Data_Is_Valid;

   function Get_Value return Integer
   --# global Last_Read;
   is
   begin
      return Last_Read;
   end Get_Value;

   procedure Read_Next
   --# global in  In_Port;
   --#        out Last_Read;
   --# derives Last_Read from In_Port;
   is
   begin
      Last_Read := In_Port;
      if not Last_Read'Valid then
         Last_Read := 0;
      end if;
   end Read_Next;

end Raw_Data;
