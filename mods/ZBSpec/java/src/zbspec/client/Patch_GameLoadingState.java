package me.zed_0xff.zbspec;

import me.zed_0xff.zombie_buddy.Accessor;
import me.zed_0xff.zombie_buddy.Patch;

import java.lang.reflect.Field;

/**
 * Patch for zombie.gameStates.GameLoadingState to force the loading screen to complete quickly.
 * This is useful for automated testing where waiting for the full loading sequence is not needed.
 */
public class Patch_GameLoadingState {
    
    /**
     * Patch the update() method to set forceDone=true before calling the original method.
     * This allows specs to skip the loading screen's "press any key to continue"
     */
    @Patch(className = "zombie.gameStates.GameLoadingState", methodName = "update")
    public static class PatchUpdate {
        public static final Field f_forceDone = Accessor.findField("zombie.gameStates.GameLoadingState", "forceDone", "bForceDone"); // changed in 42.13.1 or .2
        public static boolean msgShown = false;
        
        @Patch.OnEnter
        public static void enter(@Patch.This Object self) {
            boolean success = Accessor.trySet(self, f_forceDone, true);

            if (!msgShown) {
                msgShown = true;
                if (success) {
                    System.out.println("[ZBSpec] GameLoadingState.update() - forceDone set to true");
                } else {
                    System.err.println("[ZBSpec] ERROR: Failed to set forceDone field in GameLoadingState");
                }
            }
        }
    }
}
