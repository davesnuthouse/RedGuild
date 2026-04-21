Please feel free report new issues under issues section (full BugSack data would be ideal), or just talk to me in game.

IS ADDON CURRENTLY SAFE TO USE : YES

NOTE - YOU SHOULD ONLY USE THE RELEASE VERSION ON CURSEFORGE.  THE LUA LISTED HERE IS IN DEVELOPMENT


Missing functionality from 1.0.69:
* (Done) Master switch to turn SYNC off on Editors page
* (Done) Option for the Editors tab that shows how many known addon users. Also fixed that the addon wasn't storing data for addon users properly.
* (Done) Option on the RL tools tab that selects raid members
* (Done) Edit button for DKP tab editors
* (Done) Mangs changes - (tweaks to names of dkp table columns and "new week" button)
* (Done) Redo RL Tools functionality to make it as lightweight as possible
* (Done) Toggle for Inviter to also show online guildies who aren't on dkp table
* (Done but caused sorting bug to reappear) Filter for DKP tab to show/hide inactive users
* (Done but caused sorting bug to reappear) Filter for DKP tab to show current raid members
* (Done) Toggle for Inviter to also show online guildies who aren't on dkp table
* (Done) Enhance Inviter information and list to clearly show who's offline or in group
* Revisit audit log now that sync is working
* Inactive user option for dkp table (biggie)

Known Bugs:
* Add button also needs clicked twice (once for defocus and once to activate)
* (Fixed) DKP table headers cutoff?  (Rotation)
* Force sync to Lunatic did not show her accept in summary (cosmetic)
* Double check summary info on inviter is counting tanks properly
* When not in group you are not missing in inviter, and ML scorecard shows blank
* Editors moving to alts will allow their DKP table to be overridden by other editors because they now fall into the autosync rule.  Workaround is they do not use addon on alts.
* ML Scorecard needs reset to pull names rather than onload

Showstoppers:
* The "Show hidden records" and "Show current raid members" options on DKP tab has the old bug where it hides table rows at the end of the list.  Ultimately the DKP table has a redraw logic issue that prevents the table refreshing correctly, likely due to duplication of process or incorrect recycling of assets.  Thankfully it doesn't impact the data at all it's just a view issue that seems to get worse when you use more filters/sorting.
* Lock/Unlock funtionality has made names field unable to be edited


Features to consider for the distant future:
* Colour coding in the logs to make them easier to read
* More buttons for RL Tools
* Full support for DKP bidding
* Raid group planner






PRE RELEASE ARCHIVE
------------------------------------------------------

Missing functionality I want to add/chage ASAP:
1. (Done) Cap on weekly ontime, attendance
2. A prettier way to handle the tell/whisper option?
3. (Done) Information on the DKP tab that shows the last time that users data was synced successfully
4. (Done) Ability for folks to whisper an editor with "what's my DKP?" and get a whisper reply
5. (Done) Convert Minimap button to use Lib so it can hook into minimap addons (sexymap) better
6. (Done) Restore the missing "has rotated" data from the DKP table"
7. (Done) Restore the colours on the dkp table values that showed increases and decreases
8. (Dropped) A day lock where those buttons only work on raid days at the times we usually use them?
9. (Redundant with new functionality) A warning to the RL/ML that they have to allocate Attendance DKP before people leave the group
10. (Done) Restore the chat window slash commmands
11. (Done) Balance field shouldn't be able to be edited
12. (Done) Add button to RL Tools to allocate bench award
13. (Done) Add to the group builder info window a counter of how many people are in your group/raid and who is not from the selected users
15. (Discuss with Mang) Remove request sync button from editor
16. (Done) Retains the tickboxes on group builder (to prevent loss on a DC), due to this will also have to add a clear (and heck whynot a tick all) option.
17. (Done) Remove funcitonality to check officers... it's not really needed as the addon uses it's own editors lists to determine who shouldnt sync and where data comes from.
18. (Done - add button too) There's no username validation on editor list, would be best to only allow guild users
19. (Done) Improve EE use.
20. (Done) Improve RL tools so you can manually select who to give points to?
21. (Done) Update class/role icons to match the classes but still work on info
22. (Done) Button on ML scoreboard for filter to raid
23. (Done) Refine "Broadcast DKP" button to just people in the group/raid
24. Master switch to turn SYNC off for testing
25. (Done) Option on the Editor tab to set the DKP table version number
26. Revisit audit log now that sync is working
27. (Done) Option on the group builder to select all
28. (Done) A filter to show/hide dkp data of people who have left
29. (Done) SYNC protected to only send data to current guild members
30. Option for the Editors tab that shows how many known addon users
31. (Done) Toggle for Inviter to also show online guildies who aren't on dkp table
32. Option on the RL tools tab that selects raid members
33. (Done) Filter for DKP tab to show current raid members
34. Edit button for DKP tab editors
35. Inactive user option for dkp table (biggie)
36. Mangs changes - (redo RL tools and names of dkp table columns)
37. (Done - because someone speshul wanted this most) Mass Invite functionality
38. (Done) Some way to record players roles


Known Bugs:
1. (Fixed but blurry as all hell) Addon icon not displaying on the addons list
2. (Fixed) Top row record can show above the window when editing + scrolling
3. (Fixed) Audit log is back to showing lots of "unknowns" (display issue the data is there)
4. (Fixed) Minimap button being a twat (needs a full rebuild and Lib file)
5. (Fixed) Clicking away from edit value on DKP table doesnt deslect value (like pressing enter would)
6. (Fixed) On first load the dkp table displays blank, it takes a /reload for the data to display
7. (Fixed) It has lost formatting on the editors list due to fixing name sync issues (likely cosmetic)
8. (Fixed) After fixing 5 the window can nolonger be moved on the DKP tab
9. (Fixed) The group invites spams the user untill they accept the invite rather than once 
10. (Fixed) Personally it feels like there's a loop somewhere in the Editors code that makes it constantly check Editors, which is pointless... needs improved.
11. (Fixed) It can behave very erratically when GL/Editor is AFK or DND.  I know WHY that is but code might be able to be improved to do something else in this situation instead of fail (ie get data from another user?)
12. (Fixed) Broadcast DKP to raid is Alphabetical (Z first) reverse.
13. (Fixed - TLDR wasnt true) No editors online functionality needs imroving, most specifically the red warnings but just more ways for it to sync itself without waiting for manual.  It is possible that this is only true because of the editor sync issue.  Currently it looks like the warnings don't refresh but the addon knows an editor as come online (manual sync works).  So there's a mismatch there that needs looked into.
14. (Fixed) Notes on ML whiteboard don't work and the AI made it worse.
15. (Technically fixed as no longer exists) If previous editor gets rid of addon they get whisper spam from addon users.
16. (Fixed) On DKP whisper reply the Balance is 0
17. (Fixed) Table not refreshing after Add
18. Add button also needs clicked twice (once for defocus and once to activate)
19. (Fixed) Delete functionality causes display issue on dkp table (data is fine)
20. (Fixed?) ML tools table needs to be 'reset' to show changes to dkp table
21. DKP table headers cutoff?  (Rotation)
22. (Fixed) Not a bug but need to change feral dps to a new icon as it's the same as feral tank
23. (Fixed) Missing from group goes off the window on Inviter
24. (Fixed) Broadcast DKP broken
25. (Fixed) The column sizes on ML Scorecard aren't quite right on MS/OS so they highlight in a way that gives me autistic tingles.
26. (Fixed) Raid leader detection wasn't working (only assistant)
27. Force sync to Lunatic did not show her accept in summary
28. Double check summary info on inviter is counting tanks properly
29. When not in group you are not missing in inviter, and ML scorecard shows blank
30. The "Show hidden records" option on DKP tab has the old delete bug where it hides table rows at the end of the list.  Ultimately the DKP table has a redraw logic issue that prevents the table refresh, likely due to duplication of process or incorrect recycling of assets.  Thankfully it doesn't impact the data at all it's just a view issue that seems to get worse when you use more filters/sorting.
7. (Done) ML whiteboard
8. (Abandoned) Filter option for the dkp table
9. Guild crafting info?
10. Options screen to control variables that are currently hard coded
