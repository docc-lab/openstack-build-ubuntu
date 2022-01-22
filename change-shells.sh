#!/bin/bash
for user in $(ls /users)
do
	sudo chsh $user --shell /bin/bash
done

