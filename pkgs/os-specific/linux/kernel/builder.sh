source $stdenv/setup


makeFlags="ARCH=$arch SHELL=/bin/sh KBUILD_BUILD_VERSION=1-NixOS $makeFlags"
if [ -n "$crossConfig" ]; then
  makeFlags="$makeFlags CROSS_COMPILE=$crossConfig-"
fi

postPatch() {
    # Makefiles are full of /bin/pwd, /bin/false, /bin/bash, etc.
    # Patch these away, assuming the tools are in $PATH.
    for mf in $(find -name Makefile); do
        echo "stripping FHS paths in \`$mf'..."
        sed -i "$mf" -e 's|/usr/bin/||g ; s|/bin/||g'
    done
}

configurePhase() {
    if test -n "$preConfigure"; then
        eval "$preConfigure"
    fi

    export INSTALL_PATH=$out
    export INSTALL_MOD_PATH=$out

    # Set our own localversion, if specified.
    rm -f localversion*
    if test -n "$localVersion"; then
        echo "$localVersion" > localversion-nix
    fi

    # Patch kconfig to print "###" after every question so that
    # generate-config.pl can answer them.
    sed -e '/fflush(stdout);/i\printf("###");' -i scripts/kconfig/conf.c

    # Get a basic config file for later refinement with $generateConfig.
    make $kernelBaseConfig ARCH=$arch

    # Create the config file.
    echo "generating kernel configuration..."
    echo "$kernelConfig" > kernel-config
    DEBUG=1 ARCH=$arch KERNEL_CONFIG=kernel-config AUTO_MODULES=$autoModules \
        perl -w $generateConfig
}


installPhase() {

    mkdir -p $out

    # New kernel versions have a combined tree for i386 and x86_64.
    archDir=$arch
    if test -e arch/x86 -a \( "$arch" = i386 -o "$arch" = x86_64 \); then
        archDir=x86
    fi


    # Copy the bzImage and System.map.
    cp System.map $out
    if test "$arch" = um; then
        mkdir -p $out/bin
        cp linux $out/bin
    elif test "$kernelTarget" != "vmlinux"; then
        # In any case we copy the 'vmlinux' ELF in the next lines
        cp arch/$archDir/boot/$kernelTarget $out
    fi

    cp vmlinux $out

    if grep -q "CONFIG_MODULES=y" .config; then
        # Install the modules in $out/lib/modules.
        make modules_install \
            DEPMOD=$kmod/sbin/depmod \
            $makeFlags "${makeFlagsArray[@]}" \
            $installFlags "${installFlagsArray[@]}"

        if test -z "$dontStrip"; then
            # Strip the kernel modules.
        echo "Stripping kernel modules..."
        if [ -z "$crossConfig" ]; then
                find $out -name "*.ko" -print0 | xargs -0 strip -S
        else
                find $out -name "*.ko" -print0 | xargs -0 $crossConfig-strip -S
        fi
        fi

        # move this to install later on
        # largely copied from early FC3 kernel spec files
        version=$(cd $out/lib/modules && ls -d *)

        # remove symlinks and create directories
        rm -f $out/lib/modules/$version/build
        rm -f $out/lib/modules/$version/source
        mkdir $out/lib/modules/$version/build

        # copy config
        cp .config $out/lib/modules/$version/build/.config
        ln -s $out/lib/modules/$version/build/.config $out/config

        if test "$arch" != um; then
            # copy all Makefiles and Kconfig files
            ln -s $out/lib/modules/$version/build $out/lib/modules/$version/source
            cp --parents `find  -type f -name Makefile -o -name "Kconfig*"` $out/lib/modules/$version/build
            cp Module.symvers $out/lib/modules/$version/build

        if test "$dontStrip" = "1"; then
            # copy any debugging info that can be found
            cp --parents -rv `find -name \*.debug -o -name debug.a`     \
               "$out/lib/modules/$version/build"
        fi

            # weed out unneeded stuff
            rm -rf $out/lib/modules/$version/build/Documentation
            rm -rf $out/lib/modules/$version/build/scripts
            rm -rf $out/lib/modules/$version/build/include

            # copy architecture dependent files
            cp -a arch/$archDir/scripts $out/lib/modules/$version/build/ || true
            cp -a arch/$archDir/*lds $out/lib/modules/$version/build/ || true
            cp -a arch/$archDir/Makefile*.cpu $out/lib/modules/$version/build/arch/$archDir/ || true
            cp -a --parents arch/$archDir/kernel/asm-offsets.s $out/lib/modules/$version/build/arch/$archDir/kernel/ || true

            # copy scripts
            rm -f scripts/*.o
            rm -f scripts/*/*.o
            cp -a scripts $out/lib/modules/$version/build

            # copy include files
            includeDir=$out/lib/modules/$version/build/include
            mkdir -p $includeDir
            (cd include && cp -a * $includeDir)
        (cd arch/$archDir/include && cp -a * $includeDir || true)
        (cd arch/$archDir/include && cp -a asm/* $includeDir/asm/ || true)
        (cd arch/$archDir/include && cp -a generated/asm/* $includeDir/asm/ || true)
        (cd arch/$archDir/include/asm/mach-generic && cp -a * $includeDir/ || true)
            # include files for special arm architectures 
            if [ "$archDir" == "arm" ]; then
                cp -a --parents arch/arm/mach-*/include $out/lib/modules/$version/build
            fi
        fi
    fi

    if test -n "$postInstall"; then
        eval "$postInstall";
    fi
}


genericBuild
