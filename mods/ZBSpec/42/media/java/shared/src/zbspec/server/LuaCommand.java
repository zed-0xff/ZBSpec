package me.zed_0xff.zbspec;

import java.util.concurrent.atomic.AtomicReference;

import se.krka.kahlua.integration.LuaReturn;
import se.krka.kahlua.luaj.compiler.LuaCompiler;
import se.krka.kahlua.vm.LuaClosure;
import zombie.Lua.LuaManager;
import zombie.characters.Capability;
import zombie.characters.Role;
import zombie.commands.CommandArgs;
import zombie.commands.CommandBase;
import zombie.commands.CommandHelp;
import zombie.commands.CommandName;
import zombie.commands.RequiredCapability;
import zombie.core.raknet.UdpConnection;

import me.zed_0xff.zombie_buddy.HttpServer;

/**
 * Server command to execute Lua code.
 * Usage: /lua <code>
 * Example: /lua return getOnlinePlayers()
 */
@CommandName(name = "lua")
@CommandHelp(helpText = "Execute Lua code on the server")
@CommandArgs(varArgs = true)
@RequiredCapability(requiredCapability = Capability.DebugConsole)
public class LuaCommand extends CommandBase {
    
    public LuaCommand(String username, Role userRole, String command, UdpConnection connection) {
        super(username, userRole, command, connection);
    }

    @Override
    protected String Command() {
        // Extract Lua code from command (skip "lua ")
        String fullCommand = getFullCommandText();
        String luaCode;
        if (fullCommand.length() > 4) {
            luaCode = fullCommand.substring(4).trim();
        } else {
            return "Usage: /lua <code>";
        }
        
        if (luaCode.isEmpty()) {
            return "Usage: /lua <code>";
        }
        
        AtomicReference<String> resultRef = new AtomicReference<>();
        
        try {
            HttpServer.runOnLuaThread(() -> {
                try {
                    LuaClosure closure = LuaCompiler.loadstring(luaCode, "server_cmd", LuaManager.env);
                    LuaReturn ret = LuaManager.caller.protectedCall(LuaManager.thread, closure, new Object[0]);
                    
                    if (ret.isSuccess()) {
                        resultRef.set(ret.isEmpty() ? "nil" : String.valueOf(ret.getFirst()));
                    } else {
                        resultRef.set("Error: " + ret.getErrorString());
                    }
                } catch (Exception e) {
                    resultRef.set("Error: " + e.getMessage());
                }
            });
        } catch (Exception e) {
            return "Error: " + e.getMessage();
        }
        
        return resultRef.get();
    }
    
    private String getFullCommandText() {
        try {
            java.lang.reflect.Field field = CommandBase.class.getDeclaredField("command");
            field.setAccessible(true);
            return (String) field.get(this);
        } catch (Exception e) {
            return "";
        }
    }
}
