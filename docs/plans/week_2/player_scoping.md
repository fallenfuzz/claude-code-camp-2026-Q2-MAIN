## Player Scoping

We are on week2_capable of our implementation.

I want to seed another new player so I can have enough data in my knoweldge.sqlite3 to create information in the mud monitor.
But the problem is my entire boukensha is scoped for a single player and same with my mud monitor.

In mud monitor I would assume we would have a drop down to change between players.
Probably the easiest thing is to have a .boukensha folder per player. It would be the easiest way to isolate them.

Our .boukensharc is also a sticking point. if we used a boukensha folder for each maybe it should be ./bounkensha/<player-profile>

and when we use boukensha we have to specific the profile eg. boukensha --profile dummy

## Technical Solution
[todo]