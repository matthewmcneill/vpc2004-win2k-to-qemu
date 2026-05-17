#!/usr/bin/env python3
"""merge_split_vhd.py — Merge a VPC 2004 split dynamic VHD into a single raw image.

VPC 2004 splits large dynamic VHDs into multiple files:
  cdrive.vhd  — Header + BAM + data blocks + footer
  cdrive.v01  — Additional data blocks + footer

The BAM (Block Allocation Map) contains absolute byte offsets into the
concatenated file (with intermediate footers). This script reads the BAM
and reconstructs the full virtual disk as a raw image.

Usage: python3 merge_split_vhd.py <vhd_file> <output_raw>
"""

import struct
import sys
import os

def read_footer(data):
    """Parse a VHD footer (512 bytes)."""
    cookie = data[0:8]
    if cookie != b'conectix':
        raise ValueError(f"Invalid VHD footer magic: {cookie}")
    
    features = struct.unpack('>I', data[8:12])[0]
    version = struct.unpack('>I', data[12:16])[0]
    data_offset = struct.unpack('>Q', data[16:24])[0]
    timestamp = struct.unpack('>I', data[24:28])[0]
    creator_app = data[28:32]
    creator_ver = struct.unpack('>I', data[32:36])[0]
    creator_os = data[36:40]
    original_size = struct.unpack('>Q', data[40:48])[0]
    current_size = struct.unpack('>Q', data[48:56])[0]
    disk_geometry = struct.unpack('>I', data[56:60])[0]
    disk_type = struct.unpack('>I', data[60:64])[0]
    
    return {
        'cookie': cookie,
        'data_offset': data_offset,
        'original_size': original_size,
        'current_size': current_size,
        'disk_type': disk_type,  # 2=fixed, 3=dynamic, 4=differencing
        'creator_app': creator_app,
    }

def read_dynamic_header(data):
    """Parse a VHD dynamic disk header (1024 bytes)."""
    cookie = data[0:8]
    if cookie != b'cxsparse':
        raise ValueError(f"Invalid dynamic header magic: {cookie}")
    
    data_offset = struct.unpack('>Q', data[8:16])[0]
    table_offset = struct.unpack('>Q', data[16:24])[0]
    header_version = struct.unpack('>I', data[24:28])[0]
    max_table_entries = struct.unpack('>I', data[28:32])[0]
    block_size = struct.unpack('>I', data[32:36])[0]
    
    return {
        'table_offset': table_offset,
        'max_table_entries': max_table_entries,
        'block_size': block_size,
    }

def merge_split_vhd(vhd_path, output_path):
    """Merge a split VHD into a raw disk image."""
    
    # Find companion files (.v01, .v02, etc.)
    base = os.path.splitext(vhd_path)[0]
    split_files = [vhd_path]
    idx = 1
    while True:
        companion = f"{base}.v{idx:02d}"
        if os.path.exists(companion):
            split_files.append(companion)
            idx += 1
        else:
            break
    
    print(f"Split files found: {len(split_files)}")
    for f in split_files:
        print(f"  {os.path.basename(f)}: {os.path.getsize(f) / (1024**3):.2f} GB")
    
    # Build concatenated view
    file_boundaries = []
    offset = 0
    for f in split_files:
        size = os.path.getsize(f)
        file_boundaries.append((f, offset, size))
        offset += size
    total_size = offset
    print(f"Concatenated size: {total_size / (1024**3):.2f} GB")
    
    def read_at(abs_offset, length):
        """Read from the concatenated file view."""
        result = b''
        remaining = length
        for fpath, fstart, fsize in file_boundaries:
            if abs_offset >= fstart + fsize:
                continue
            if abs_offset < fstart:
                continue
            local_offset = abs_offset - fstart
            to_read = min(remaining, fsize - local_offset)
            with open(fpath, 'rb') as f:
                f.seek(local_offset)
                result += f.read(to_read)
            remaining -= to_read
            abs_offset += to_read
            if remaining <= 0:
                break
        return result
    
    # Read footer from end of last file
    footer_data = read_at(total_size - 512, 512)
    footer = read_footer(footer_data)
    print(f"\nVHD Footer:")
    print(f"  Disk type: {footer['disk_type']} ({'dynamic' if footer['disk_type'] == 3 else 'other'})")
    print(f"  Virtual size: {footer['current_size'] / (1024**3):.2f} GB")
    print(f"  Creator: {footer['creator_app']}")
    
    if footer['disk_type'] != 3:
        raise ValueError(f"Expected dynamic disk (type 3), got type {footer['disk_type']}")
    
    # Read copy of footer at start + dynamic header
    footer_copy = read_at(0, 512)
    dyn_header_data = read_at(512, 1024)
    dyn_header = read_dynamic_header(dyn_header_data)
    
    block_size = dyn_header['block_size']
    max_entries = dyn_header['max_table_entries']
    table_offset = dyn_header['table_offset']
    
    # Each block has a bitmap (512 bytes per 2MB default) prepended
    # The bitmap size is block_size / (512 * 8) rounded up to 512-byte boundary
    bitmap_size = ((block_size // 512 + 7) // 8 + 511) // 512 * 512
    
    print(f"\nDynamic Header:")
    print(f"  Block size: {block_size / (1024**2):.0f} MB")
    print(f"  Max entries (blocks): {max_entries}")
    print(f"  BAM offset: {table_offset}")
    print(f"  Bitmap size per block: {bitmap_size} bytes")
    
    # Read BAM
    bam_size = max_entries * 4
    bam_data = read_at(table_offset, bam_size)
    
    # Parse BAM entries
    allocated = 0
    unallocated = 0
    bam_entries = []
    for i in range(max_entries):
        entry = struct.unpack('>I', bam_data[i*4:(i+1)*4])[0]
        bam_entries.append(entry)
        if entry == 0xFFFFFFFF:
            unallocated += 1
        else:
            allocated += 1
    
    print(f"\nBAM: {allocated} allocated, {unallocated} unallocated out of {max_entries}")
    
    # Create output raw image
    virtual_size = footer['current_size']
    print(f"\nCreating raw image: {virtual_size / (1024**3):.2f} GB")
    
    with open(output_path, 'wb') as out:
        # Pre-allocate with zeros (sparse)
        out.seek(virtual_size - 1)
        out.write(b'\x00')
        out.seek(0)
        
        written = 0
        for i, entry in enumerate(bam_entries):
            if entry == 0xFFFFFFFF:
                continue
            
            # Entry is a sector offset; each sector is 512 bytes
            block_offset = entry * 512
            
            # Skip the bitmap, read the actual data block
            data = read_at(block_offset + bitmap_size, block_size)
            
            # Write to the correct position in the raw image
            virtual_offset = i * block_size
            out.seek(virtual_offset)
            out.write(data)
            written += 1
            
            if written % 100 == 0:
                pct = (i / max_entries) * 100
                print(f"  {pct:.1f}% ({written} blocks written)", end='\r')
        
        print(f"\n  Done: {written} blocks written ({written * block_size / (1024**3):.2f} GB)")
    
    print(f"\nOutput: {output_path}")
    print(f"Size: {os.path.getsize(output_path) / (1024**3):.2f} GB")

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <vhd_file> <output_raw>")
        sys.exit(1)
    
    merge_split_vhd(sys.argv[1], sys.argv[2])
