Addon is currently in prerelease so multiple errors are expected.

Please report these under issues section (full BugSack data would be ideal)

Showstoppers:

1. SYNC fuctionality is still not working - This has caused 2 days of bug fixing, testing and pain... in the end the whole thing was scrapped and redone and then scrapped and redon... it's now ready to test a shiney new version.   TL:DR - Blizzard API go fuck yourself.


Missing functionality I want to add ASAP:
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
15. Remove request sync button from editor
16. Retains the tickboxes on group builder (to prevent loss on a DC), due to this will also have to add a clear (and heck whynot a tick all) option.


Known Bugs:
1. (Fixed but blurry as all hell) Addon icon not displaying on the addons list
2. (Fixed) Top row record can show above the window when editing + scrolling
3. (Possibly Fixed) Audit log is back to showing lots of "unknowns" (display issue the data is there)
4. (Fixed) Minimap button being a twat (needs a full rebuild and Lib file)
5. (Fixed) Clicking away from edit value on DKP table doesnt deslect value (like pressing enter would)
6. (Fixed) On first load the dkp table displays blank, it takes a /reload for the data to display
7. It has lost formatting on the editors list due to fixing name sync issues (likely cosmetic)
8. (Fixed) After fixing 5 the window can nolonger be moved on the DKP tab
9. (Fixed) The group invites spams the user untill they accept the invite rather than once
10. Currently only views the top 3 ranks of the guild as officer


Features to consider for the distant future:
1. Colour coding in the logs to make them easier to read
2. More buttons for RL Tools
3. Full support for DKP bidding
4. (Done - because someone speshul wanted this most) Mass Invite functionality
5. Raid group planner?
6. (Done) Some way to record players roles
7. ML whiteboard
8. Filter option for the dkp table
