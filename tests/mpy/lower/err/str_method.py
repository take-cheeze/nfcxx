# A str method that the reference does not have (MicroPython 1.29 has no str.title, so its call is an AttributeError there): it is
# refused by name.
result = 'hello world'.title()
