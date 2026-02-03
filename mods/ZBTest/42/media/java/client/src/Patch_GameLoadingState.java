package me.zed_0xff.zbtest;

import me.zed_0xff.zombie_buddy.Patch;

public class Patch_GameLoadingState {
    
    /**
     * Patch the update() method to set forceDone=true before calling the original method.
     * This allows tests to skip the loading screen's "press any key to continue"
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
                    System.out.println("[ZBTest] GameLoadingState.update() - forceDone set to true");
                    msgShown = true;
                }
            } catch (NoSuchFieldException e) {
                System.err.println("[ZBTest] ERROR: Could not find forceDone field in GameLoadingState");
                e.printStackTrace();
            } catch (IllegalAccessException e) {
                System.err.println("[ZBTest] ERROR: Could not access forceDone field in GameLoadingState");
                e.printStackTrace();
            }
        }
    }
}
