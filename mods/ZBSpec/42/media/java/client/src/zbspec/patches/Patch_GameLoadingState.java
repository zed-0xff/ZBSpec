package zbspec.patches;

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
        public static void enter(@Patch.This Object self) {
            try {
                // Access the private forceDone field using reflection
                java.lang.reflect.Field forceDoneField = self.getClass().getDeclaredField("forceDone");
                forceDoneField.setAccessible(true);
                
                forceDoneField.setBoolean(self, true);
                
                if (!msgShown) {
                    System.out.println("[ZBSpec] GameLoadingState.update() - forceDone set to true");
                    msgShown = true;
                }
            } catch (NoSuchFieldException e) {
                System.err.println("[ZBSpec] ERROR: Could not find forceDone field in GameLoadingState");
                e.printStackTrace();
            } catch (IllegalAccessException e) {
                System.err.println("[ZBSpec] ERROR: Could not access forceDone field in GameLoadingState");
                e.printStackTrace();
            }
        }
    }
}
