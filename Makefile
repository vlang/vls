.DEFAULT_GOAL := install

install:
	v -prod cmd/vls
pull:
	git pull origin master
update: pull install
