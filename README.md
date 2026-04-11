Addon is currently in prerelease so multiple errors are expected.

Please report these under issues section (full BugSack data would be ideal)

IS ADDON CURRENTLY SAFE TO USE : YES
PLEASE NOTE - There's still a lot of error handling turned on so at times it might tell you things in chat that eventually it wont.  It also needs Lunátic to be online for it to pull data but that's next on the things to fix list.


Showstoppers:

1. SYNC fuctionality WORKS!  However... SYNC is still not pulling down the editors list to the users machines.  That's not strictly show stopping for view but it does prevent anyone but me from updating it which is not ideal.
2. Editor list sync now needs debugging to figure out where it's struggling.


Missing functionality I want to add/chage ASAP:
1. (Done) Cap on weekly ontime, attendance
2. A prettier way to handle the tell/whisper option?
3. Information on the DKP tab that shows the last time that users data was synced successfully
4. Ability for folks to whisper an editor with "what's my DKP?" and get a whisper reply
5. (Done) Convert Minimap button to use Lib so it can hook into minimap addons (sexymap) better
6. (Done) Restore the missing "has rotated" data from the DKP table"
7. (Done) Restore the colours on the dkp table values that showed increases and decreases
8. A day lock where those buttons only work on raid days at the times we usually use them?
9. A warning to the RL/ML that they have to allocate Attendance DKP before people leave the group
10. (Done) Restore the chat window slash commmands
11. (Done) Balance field shouldn't be able to be edited
12. Add button to RL Tools to allocate bench award
13. Add to the group builder info window a counter of how many people are in your group/raid and who is not from the selected users
15. (Discuss with Mang) Remove request sync button from editor
16. Retains the tickboxes on group builder (to prevent loss on a DC), due to this will also have to add a clear (and heck whynot a tick all) option.
17. (Done) Remove funcitonality to check officers... it's not really needed as the addon uses it's own editors lists to determine who shouldnt sync and where data comes from.
18. (Done - add button too) There's no username validation on editor list, would be best to only allow guild users
19. Improve EE use.


Known Bugs:
1. (Fixed but blurry as all hell) Addon icon not displaying on the addons list
2. (Fixed) Top row record can show above the window when editing + scrolling
3. (Fixed) Audit log is back to showing lots of "unknowns" (display issue the data is there)
4. (Fixed) Minimap button being a twat (needs a full rebuild and Lib file)
5. (Fixed) Clicking away from edit value on DKP table doesnt deslect value (like pressing enter would)
6. (Fixed) On first load the dkp table displays blank, it takes a /reload for the data to display
7. (fixed) It has lost formatting on the editors list due to fixing name sync issues (likely cosmetic)
8. (Fixed) After fixing 5 the window can nolonger be moved on the DKP tab
9. (Fixed) The group invites spams the user untill they accept the invite rather than once 
10. (Fixed) Personally it feels like there's a loop somewhere in the Editors code that makes it constantly check Editors, which is pointless... needs improved.
11. It can behave very erratically when GL/Editor is AFK or DND.  I know WHY that is but code might be able to be improved to do something else in this situation instead of fail (ie get data from another user?)
12. (Fixed) Broadcast DKP to raid is Alphabetical (Z first) reverse.
13. (Fixed - TLDR wasnt true) No editors online functionality needs imroving, most specifically the red warnings but just more ways for it to sync itself without waiting for manual.  It is possible that this is only true because of the editor sync issue.  Currently it looks like the warnings don't refresh but the addon knows an editor as come online (manual sync works).  So there's a mismatch there that needs looked into.
14. Notes on ML whiteboard don't work and the AI made it worse.
15. (fixed) If previous editor gets rid of addon they get whisper spam from addon users.
16. On DKP whisper reply the Balance is 0


Features to consider for the distant future:
1. Colour coding in the logs to make them easier to read
2. More buttons for RL Tools
3. Full support for DKP bidding
4. (Done - because someone speshul wanted this most) Mass Invite functionality
5. Raid group planner?
6. (Done) Some way to record players roles
7. (Done) ML whiteboard
8. Filter option for the dkp table
9. Guild crafting info?


Next tests:

1. Editor Sync over and over again till it's figured out
2. Whisper function
