package me.zed_0xff.zbspec;

import me.zed_0xff.zombie_buddy.Patch;

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
        public static boolean msgShown = false;
        
        @Patch.OnEnter
        public static void enter(@Patch.FieldRW({"forceDone", "bForceDone"}) boolean forceDone) {
            forceDone = true;

            if (!msgShown) {
                msgShown = true;
                System.out.println("[ZBSpec] GameLoadingState.update() - forceDone set to true");
            }
        }
    }
}
