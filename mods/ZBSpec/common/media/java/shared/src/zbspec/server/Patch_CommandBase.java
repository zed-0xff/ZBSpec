package me.zed_0xff.zbspec;

/*
 * COMMENTED OUT - replaced by sendClientCommand/server_exec pattern in ZBSpec.lua
 *

import me.zed_0xff.zombie_buddy.Patch;

// Patch CommandBase.findCommandCls to return LuaCommand.class for "/lua" commands.

@Patch(className = "zombie.commands.CommandBase", methodName = "findCommandCls")
public class Patch_CommandBase {
    
    @Patch.OnExit
    public static void exit(@Patch.Argument(0) String command,
                           @Patch.Return(readOnly = false) Class<?> returnValue) {
        if (returnValue != null) {
            return;
        }
        if (command != null && command.toLowerCase().startsWith("lua ")) {
            returnValue = LuaCommand.class;
        }
    }
}

*/
