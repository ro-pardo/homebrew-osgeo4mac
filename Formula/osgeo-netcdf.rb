class Unlinked < Requirement
  fatal true

  satisfy(:build_env => false) { !core_netcdf_linked }

  def core_netcdf_linked
    Formula["netcdf"].linked_keg.exist?
  rescue
    return false
  end

  def message
    s = "\033[31mYou have other linked versions!\e[0m\n\n"

    s += "Unlink with \e[32mbrew unlink netcdf\e[0m or remove with \e[32mbrew uninstall --ignore-dependencies netcdf\e[0m\n\n" if core_netcdf_linked
    s
  end
end

class OsgeoNetcdf < Formula
  desc "Libraries and data formats for array-oriented scientific data"
  homepage "https://www.unidata.ucar.edu/software/netcdf"
  mirror "https://www.unidata.ucar.edu/downloads/netcdf/ftp/netcdf-c-4.7.4.tar.gz"
  url "https://www.gfd-dennou.org/arch/netcdf/unidata-mirror/netcdf-c-4.7.4.tar.gz"
  sha256 "0e476f00aeed95af8771ff2727b7a15b2de353fb7bb3074a0d340b55c2bd4ea8"

  # revision 1

  # keg_only "netcdf is already provided by homebrew/core"
  # we will verify that other versions are not linked
  depends_on Unlinked

  depends_on "cmake" => :build
  depends_on "gcc" # for gfortran
  depends_on "hdf5"

  uses_from_macos "curl"

  resource "cxx" do
    mirror "https://www.unidata.ucar.edu/downloads/netcdf/ftp/netcdf-cxx4-4.3.1.tar.gz"
    url "https://www.gfd-dennou.org/arch/netcdf/unidata-mirror/netcdf-cxx4-4.3.1.tar.gz"
    sha256 "6a1189a181eed043b5859e15d5c080c30d0e107406fbb212c8fb9814e90f3445"
  end

  resource "cxx-compat" do
    mirror "https://www.unidata.ucar.edu/downloads/netcdf/ftp/netcdf-cxx-4.2.tar.gz"
    url "https://www.gfd-dennou.org/arch/netcdf/unidata-mirror/netcdf-cxx-4.2.tar.gz"
    sha256 "95ed6ab49a0ee001255eac4e44aacb5ca4ea96ba850c08337a3e4c9a0872ccd1"
  end

  resource "fortran" do
    mirror "https://www.unidata.ucar.edu/downloads/netcdf/ftp/netcdf-fortran-4.5.2.tar.gz"
    url "https://www.gfd-dennou.org/arch/netcdf/unidata-mirror/netcdf-fortran-4.5.2.tar.gz"
    sha256 "b959937d7d9045184e9d2040a915d94a7f4d0185f4a9dceb8f08c94b0c3304aa"
  end

  def install
    ENV.deparallelize

    common_args = std_cmake_args << "-DBUILD_TESTING=OFF"

    mkdir "build" do
      args = common_args.dup
      args << "-DNC_EXTRA_DEPS=-lmpi" if Tab.for_name("hdf5").with? "mpi"
      args << "-DENABLE_TESTS=OFF" << "-DENABLE_NETCDF_4=ON" << "-DENABLE_DOXYGEN=OFF"

      system "cmake", "..", "-DBUILD_SHARED_LIBS=ON", *args
      system "make", "install"
      system "make", "clean"
      system "cmake", "..", "-DBUILD_SHARED_LIBS=OFF", *args
      system "make"
      lib.install "liblib/libnetcdf.a"
    end

    # Add newly created installation to paths so that binding libraries can
    # find the core libs.
    args = common_args.dup << "-DNETCDF_C_LIBRARY=#{lib}/libnetcdf.dylib"

    cxx_args = args.dup
    cxx_args << "-DNCXX_ENABLE_TESTS=OFF"
    resource("cxx").stage do
      mkdir "build-cxx" do
        system "cmake", "..", "-DBUILD_SHARED_LIBS=ON", *cxx_args
        system "make", "install"
        system "make", "clean"
        system "cmake", "..", "-DBUILD_SHARED_LIBS=OFF", *cxx_args
        system "make"
        lib.install "cxx4/libnetcdf-cxx4.a"
      end
    end

    fortran_args = args.dup
    fortran_args << "-DENABLE_TESTS=OFF"
    resource("fortran").stage do
      mkdir "build-fortran" do
        system "cmake", "..", "-DBUILD_SHARED_LIBS=ON", *fortran_args
        system "make", "install"
        system "make", "clean"
        system "cmake", "..", "-DBUILD_SHARED_LIBS=OFF", *fortran_args
        system "make"
        lib.install "fortran/libnetcdff.a"
      end
    end

    ENV.prepend "CPPFLAGS", "-I#{include}"
    ENV.prepend "LDFLAGS", "-L#{lib}"
    resource("cxx-compat").stage do
      system "./configure", "--disable-dependency-tracking",
                            "--enable-shared",
                            "--enable-static",
                            "--prefix=#{prefix}"
      system "make"
      system "make", "install"
    end

    # SIP causes system Python not to play nicely with @rpath
    libnetcdf = (lib/"libnetcdf.dylib").readlink
    %w[libnetcdf-cxx4.dylib libnetcdf_c++.dylib].each do |f|
      macho = MachO.open("#{lib}/#{f}")
      macho.change_dylib("@rpath/#{libnetcdf}",
                         "#{lib}/#{libnetcdf}")
      macho.write!
    end
  end

  test do
    (testpath/"test.c").write <<~EOS
      #include <stdio.h>
      #include "netcdf_meta.h"
      int main()
      {
        printf(NC_VERSION);
        return 0;
      }
    EOS
    system ENV.cc, "test.c", "-L#{lib}", "-I#{include}", "-lnetcdf",
                   "-o", "test"
    if head?
      assert_match /^\d+(?:\.\d+)+/, `./test`
    else
      assert_equal version.to_s, `./test`
    end

    (testpath/"test.f90").write <<~EOS
      program test
        use netcdf
        integer :: ncid, varid, dimids(2)
        integer :: dat(2,2) = reshape([1, 2, 3, 4], [2, 2])
        call check( nf90_create("test.nc", NF90_CLOBBER, ncid) )
        call check( nf90_def_dim(ncid, "x", 2, dimids(2)) )
        call check( nf90_def_dim(ncid, "y", 2, dimids(1)) )
        call check( nf90_def_var(ncid, "data", NF90_INT, dimids, varid) )
        call check( nf90_enddef(ncid) )
        call check( nf90_put_var(ncid, varid, dat) )
        call check( nf90_close(ncid) )
      contains
        subroutine check(status)
          integer, intent(in) :: status
          if (status /= nf90_noerr) call abort
        end subroutine check
      end program test
    EOS
    system "gfortran", "test.f90", "-L#{lib}", "-I#{include}", "-lnetcdff",
                       "-o", "testf"
    system "./testf"
  end
end