# Important
I wanna be honest about LLM usage for this project, which is why this is the first thing you read in this README.

I use Claude as a co-developer, talking through ideas, concepts, but also letting it generate code. With exact instructions that I give.
I aim to keep stuff I don't understand to an absolute bare minimum, but also keep in mind that this is mainly a learning project for me
as I dive deeper and deeper into low-level development. I just actually have to see and use code I may not understand fully right now, to 
understand it later.

# OwOS
> pronounced **"O-woh-S"**

OwOS is supposed to become a custom non-POSIX-compliant x86_64 OS with a big focus on privacy and security. This is **not** supposed to be
a general purpose desktop OS for everyone. Which is why I made a few design choices that not everyone might approve of at first, but that 
I think actually make sense for the scope of this project.

### No Userland
One of the most important things when it comes to this OS is that there is **no** userland. Everything runs at kernel level, ring 0. This is
because - while the reason is also userland being very hard to implement, especially for a beginner - it just introduces another possible point
of failure.

When everything runs in ring 0, I am forced to write absolutely stable code that will not crash the whole kernel at a single small mistake, which
I personally think is beneficial.
> Furthermore, it is supposed to be a fully monolithic OS, without much modularity. No multi-user system. No "just change
your DE or WM". No "install this package" or "download that theme".

### Apps/Programs
OwOS will come with a small collection of tools and programs that are part of the kernel code and thus compiled into the binary. These will include:
- **Crate**: A simple file manager
- **BEFO**: A simple file/text editor ("**B**asic **E**ditor **F**or **O**wOS")
- **Shelly**: A terminal, your main way of interacting with the OS

### Security
You might've asked yourself how OwOS does security and privacy. *How* it achieves that is relatively simple: Most of the work is done by a custom
encrypted RAMFS (which is everything but simple in how it works under the hood).

OwOS uses a custom filesystem and filesystem management where each file is encrypted with its own key, at write time. Reading data from it decrypts
the data using the file's key **only** at read time. The host's internal drives are never touched.
> to be continued soon...

## Features
- Custom encrypted RAMFS
