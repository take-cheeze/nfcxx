# calling a def before the module has run it
result = later_function_xyz()

def later_function_xyz():
    return 1
