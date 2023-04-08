//! This structure represents a SPIR-V (sections) module being compiled, and keeps track of all relevant information.
//! That includes the actual instructions, the current result-id bound, and data structures for querying result-id's
//! of data which needs to be persistent over different calls to Decl code generation.
//!
//! A SPIR-V binary module supports both little- and big endian layout. The layout is detected by the magic word in the
//! header. Therefore, we can ignore any byte order throughout the implementation, and just use the host byte order,
//! and make this a problem for the consumer.
const Module = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const ZigDecl = @import("../../Module.zig").Decl;

const spec = @import("spec.zig");
const Word = spec.Word;
const IdRef = spec.IdRef;
const IdResult = spec.IdResult;
const IdResultType = spec.IdResultType;

const Section = @import("Section.zig");
const Type = @import("type.zig").Type;

const TypeCache = std.ArrayHashMapUnmanaged(Type, IdResultType, Type.ShallowHashContext32, true);

/// This structure represents a function that is in-progress of being emitted.
/// Commonly, the contents of this structure will be merged with the appropriate
/// sections of the module and re-used. Note that the SPIR-V module system makes
/// no attempt of compacting result-id's, so any Fn instance should ultimately
/// be merged into the module it's result-id's are allocated from.
pub const Fn = struct {
    /// The prologue of this function; this section contains the function's
    /// OpFunction, OpFunctionParameter, OpLabel and OpVariable instructions, and
    /// is separated from the actual function contents as OpVariable instructions
    /// must appear in the first block of a function definition.
    prologue: Section = .{},
    /// The code of the body of this function.
    /// This section should also contain the OpFunctionEnd instruction marking
    /// the end of this function definition.
    body: Section = .{},

    /// Reset this function without deallocating resources, so that
    /// it may be used to emit code for another function.
    pub fn reset(self: *Fn) void {
        self.prologue.reset();
        self.body.reset();
    }

    /// Free the resources owned by this function.
    pub fn deinit(self: *Fn, a: Allocator) void {
        self.prologue.deinit(a);
        self.body.deinit(a);
        self.* = undefined;
    }
};

/// Globals must be kept in order: operations involving globals must be ordered
/// so that the global declaration precedes any usage.
pub const Global = struct {
    /// Index type to refer to a global by.
    pub const Index = enum(u32) { _ };

    /// The result-id to be used for this global declaration. Note that this does not
    /// necessarily refer to an OpVariable instruction - it may also be the final result
    /// id of a number of OpSpecConstantOp instructions.
    result_id: IdRef,
    /// The offset into `self.globals.section` of the first instruction of this global
    /// declaration.
    begin_inst: u32,
    /// The past-end offset into `self.flobals.section`.
    end_inst: u32,
    /// The first dependency in the `self.globals.dependencies` array list.
    begin_dep: u32,
    /// The past-end dependency in `self.globals.dependencies`.
    end_dep: u32,
};

/// A general-purpose allocator which may be used to allocate resources for this module
gpa: Allocator,

/// An arena allocator used to store things that have the same lifetime as this module.
arena: Allocator,

/// Module layout, according to SPIR-V Spec section 2.4, "Logical Layout of a Module".
sections: struct {
    /// Capability instructions
    capabilities: Section = .{},
    /// OpExtension instructions
    extensions: Section = .{},
    // OpExtInstImport instructions - skip for now.
    // memory model defined by target, not required here.
    /// OpEntryPoint instructions.
    entry_points: Section = .{},
    /// OpExecutionMode and OpExecutionModeId instructions.
    execution_modes: Section = .{},
    /// OpString, OpSourcExtension, OpSource, OpSourceContinued.
    debug_strings: Section = .{},
    // OpName, OpMemberName.
    debug_names: Section = .{},
    // OpModuleProcessed - skip for now.
    /// Annotation instructions (OpDecorate etc).
    annotations: Section = .{},
    /// Type declarations, constants, global variables
    /// Below this section, OpLine and OpNoLine is allowed.
    types_globals_constants: Section = .{},
    // Functions without a body - skip for now.
    /// Regular function definitions.
    functions: Section = .{},
} = .{},

/// SPIR-V instructions return result-ids. This variable holds the module-wide counter for these.
next_result_id: Word,

/// Cache for results of OpString instructions for module file names fed to OpSource.
/// Since OpString is pretty much only used for those, we don't need to keep track of all strings,
/// just the ones for OpLine. Note that OpLine needs the result of OpString, and not that of OpSource.
source_file_names: std.StringHashMapUnmanaged(IdRef) = .{},

/// SPIR-V type cache. Note that according to SPIR-V spec section 2.8, Types and Variables, non-pointer
/// non-aggrerate types (which includes matrices and vectors) must have a _unique_ representation in
/// the final binary.
/// Note: Uses ArrayHashMap which is insertion ordered, so that we may refer to other types by index (Type.Ref).
type_cache: TypeCache = .{},

/// The fields in this structure help to maintain the required order for global variables.
globals: struct {
    /// The graph nodes of global variables present in the module.
    nodes: std.ArrayListUnmanaged(Global) = .{},
    /// This pseudo-section contains the initialization code for all the globals. Instructions from
    /// here are reordered when flushing the module. Its contents should be part of the
    /// `types_globals_constants` SPIR-V section.
    section: Section = .{},
    /// Holds a list of dependent global variables for each global variable.
    dependencies: std.ArrayListUnmanaged(Global.Index) = .{},
    /// The global that initialization code/dependencies are currently being generated for, if any.
    current_global: ?Global.Index = null,
} = .{},

pub fn init(gpa: Allocator, arena: Allocator) Module {
    return .{
        .gpa = gpa,
        .arena = arena,
        .next_result_id = 1, // 0 is an invalid SPIR-V result id, so start counting at 1.
    };
}

pub fn deinit(self: *Module) void {
    self.sections.capabilities.deinit(self.gpa);
    self.sections.extensions.deinit(self.gpa);
    self.sections.entry_points.deinit(self.gpa);
    self.sections.execution_modes.deinit(self.gpa);
    self.sections.debug_strings.deinit(self.gpa);
    self.sections.debug_names.deinit(self.gpa);
    self.sections.annotations.deinit(self.gpa);
    self.sections.types_globals_constants.deinit(self.gpa);
    self.sections.functions.deinit(self.gpa);

    self.source_file_names.deinit(self.gpa);
    self.type_cache.deinit(self.gpa);

    self.globals.nodes.deinit(self.gpa);
    self.globals.section.deinit(self.gpa);
    self.globals.dependencies.deinit(self.gpa);

    self.* = undefined;
}

pub fn allocId(self: *Module) spec.IdResult {
    defer self.next_result_id += 1;
    return .{ .id = self.next_result_id };
}

pub fn allocIds(self: *Module, n: u32) spec.IdResult {
    defer self.next_result_id += n;
    return .{ .id = self.next_result_id };
}

pub fn idBound(self: Module) Word {
    return self.next_result_id;
}

fn orderGlobalsInto(
    self: Module,
    global_index: Global.Index,
    section: *Section,
    seen: *std.DynamicBitSetUnmanaged,
) !void {
    const node = self.globals.nodes.items[@enumToInt(global_index)];
    const deps = self.globals.dependencies.items[node.begin_dep .. node.end_dep];
    const insts = self.globals.section.instructions.items[node.begin_inst .. node.end_inst];

    seen.set(@enumToInt(global_index));

    for (deps) |dep| {
        if (!seen.isSet(@enumToInt(dep))) {
            try self.orderGlobalsInto(dep, section, seen);
        }
    }

    try section.instructions.appendSlice(self.gpa, insts);
}

fn orderGlobals(self: Module) !Section {
    const nodes = self.globals.nodes.items;

    var seen = try std.DynamicBitSetUnmanaged.initEmpty(self.gpa, nodes.len);
    defer seen.deinit(self.gpa);

    var ordered_globals = Section{};

    for (0..nodes.len) |global_index| {
        if (!seen.isSet(global_index)) {
            try self.orderGlobalsInto(@intToEnum(Global.Index, @intCast(u32, global_index)), &ordered_globals, &seen);
        }
    }

    return ordered_globals;
}

/// Emit this module as a spir-v binary.
pub fn flush(self: Module, file: std.fs.File) !void {
    // See SPIR-V Spec section 2.3, "Physical Layout of a SPIR-V Module and Instruction"

    const header = [_]Word{
        spec.magic_number,
        (1 << 16) | (4 << 8), // TODO: From cpu features
        0, // TODO: Register Zig compiler magic number.
        self.idBound(),
        0, // Schema (currently reserved for future use)
    };

    // TODO: Perform topological sort on the globals.
    var globals = try self.orderGlobals();
    defer globals.deinit(self.gpa);

    // Note: needs to be kept in order according to section 2.3!
    const buffers = &[_][]const Word{
        &header,
        self.sections.capabilities.toWords(),
        self.sections.extensions.toWords(),
        self.sections.entry_points.toWords(),
        self.sections.execution_modes.toWords(),
        self.sections.debug_strings.toWords(),
        self.sections.debug_names.toWords(),
        self.sections.annotations.toWords(),
        self.sections.types_globals_constants.toWords(),
        globals.toWords(),
        self.sections.functions.toWords(),
    };

    var iovc_buffers: [buffers.len]std.os.iovec_const = undefined;
    var file_size: u64 = 0;
    for (&iovc_buffers, 0..) |*iovc, i| {
        // Note, since spir-v supports both little and big endian we can ignore byte order here and
        // just treat the words as a sequence of bytes.
        const bytes = std.mem.sliceAsBytes(buffers[i]);
        iovc.* = .{ .iov_base = bytes.ptr, .iov_len = bytes.len };
        file_size += bytes.len;
    }

    try file.seekTo(0);
    try file.setEndPos(file_size);
    try file.pwritevAll(&iovc_buffers, 0);
}

/// Merge the sections making up a function declaration into this module.
pub fn addFunction(self: *Module, func: Fn) !void {
    try self.sections.functions.append(self.gpa, func.prologue);
    try self.sections.functions.append(self.gpa, func.body);
}

/// Fetch the result-id of an OpString instruction that encodes the path of the source
/// file of the decl. This function may also emit an OpSource with source-level information regarding
/// the decl.
pub fn resolveSourceFileName(self: *Module, decl: *ZigDecl) !IdRef {
    const path = decl.getFileScope().sub_file_path;
    const result = try self.source_file_names.getOrPut(self.gpa, path);
    if (!result.found_existing) {
        const file_result_id = self.allocId();
        result.value_ptr.* = file_result_id;
        try self.sections.debug_strings.emit(self.gpa, .OpString, .{
            .id_result = file_result_id,
            .string = path,
        });

        try self.sections.debug_strings.emit(self.gpa, .OpSource, .{
            .source_language = .Unknown, // TODO: Register Zig source language.
            .version = 0, // TODO: Zig version as u32?
            .file = file_result_id,
            .source = null, // TODO: Store actual source also?
        });
    }

    return result.value_ptr.*;
}

/// Fetch a result-id for a spir-v type. This function deduplicates the type as appropriate,
/// and returns a cached version if that exists.
/// Note: This function does not attempt to perform any validation on the type.
/// The type is emitted in a shallow fashion; any child types should already
/// be emitted at this point.
pub fn resolveType(self: *Module, ty: Type) !Type.Ref {
    const result = try self.type_cache.getOrPut(self.gpa, ty);
    if (!result.found_existing) {
        result.value_ptr.* = try self.emitType(ty);
    }

    return @intToEnum(Type.Ref, result.index);
}

pub fn resolveTypeId(self: *Module, ty: Type) !IdResultType {
    const ty_ref = try self.resolveType(ty);
    return self.typeId(ty_ref);
}

pub fn typeRefType(self: Module, ty_ref: Type.Ref) Type {
    return self.type_cache.keys()[@enumToInt(ty_ref)];
}

/// Get the result-id of a particular type, by reference. Asserts type_ref is valid.
pub fn typeId(self: Module, ty_ref: Type.Ref) IdResultType {
    return self.type_cache.values()[@enumToInt(ty_ref)];
}

/// Unconditionally emit a spir-v type into the appropriate section.
/// Note: If this function is called with a type that is already generated, it may yield an invalid module
/// as non-pointer non-aggregrate types must me unique!
/// Note: This function does not attempt to perform any validation on the type.
/// The type is emitted in a shallow fashion; any child types should already
/// be emitted at this point.
pub fn emitType(self: *Module, ty: Type) error{OutOfMemory}!IdResultType {
    const result_id = self.allocId();
    const ref_id = result_id;
    const types = &self.sections.types_globals_constants;
    const debug_names = &self.sections.debug_names;
    const result_id_operand = .{ .id_result = result_id };

    switch (ty.tag()) {
        .void => {
            try types.emit(self.gpa, .OpTypeVoid, result_id_operand);
            try debug_names.emit(self.gpa, .OpName, .{
                .target = result_id,
                .name = "void",
            });
        },
        .bool => {
            try types.emit(self.gpa, .OpTypeBool, result_id_operand);
            try debug_names.emit(self.gpa, .OpName, .{
                .target = result_id,
                .name = "bool",
            });
        },
        .u8,
        .u16,
        .u32,
        .u64,
        .i8,
        .i16,
        .i32,
        .i64,
        .int,
        => {
            // TODO: Kernels do not support OpTypeInt that is signed. We can probably
            // can get rid of the signedness all together, in Shaders also.
            const bits = ty.intFloatBits();
            const signedness: spec.LiteralInteger = switch (ty.intSignedness()) {
                .unsigned => 0,
                .signed => 1,
            };

            try types.emit(self.gpa, .OpTypeInt, .{
                .id_result = result_id,
                .width = bits,
                .signedness = signedness,
            });

            const ui: []const u8 = switch (signedness) {
                0 => "u",
                1 => "i",
                else => unreachable,
            };
            const name = try std.fmt.allocPrint(self.gpa, "{s}{}", .{ ui, bits });
            defer self.gpa.free(name);

            try debug_names.emit(self.gpa, .OpName, .{
                .target = result_id,
                .name = name,
            });
        },
        .f16, .f32, .f64 => {
            const bits = ty.intFloatBits();
            try types.emit(self.gpa, .OpTypeFloat, .{
                .id_result = result_id,
                .width = bits,
            });

            const name = try std.fmt.allocPrint(self.gpa, "f{}", .{bits});
            defer self.gpa.free(name);
            try debug_names.emit(self.gpa, .OpName, .{
                .target = result_id,
                .name = name,
            });
        },
        .vector => try types.emit(self.gpa, .OpTypeVector, .{
            .id_result = result_id,
            .component_type = self.typeId(ty.childType()),
            .component_count = ty.payload(.vector).component_count,
        }),
        .matrix => try types.emit(self.gpa, .OpTypeMatrix, .{
            .id_result = result_id,
            .column_type = self.typeId(ty.childType()),
            .column_count = ty.payload(.matrix).column_count,
        }),
        .image => {
            const info = ty.payload(.image);
            try types.emit(self.gpa, .OpTypeImage, .{
                .id_result = result_id,
                .sampled_type = self.typeId(ty.childType()),
                .dim = info.dim,
                .depth = @enumToInt(info.depth),
                .arrayed = @boolToInt(info.arrayed),
                .ms = @boolToInt(info.multisampled),
                .sampled = @enumToInt(info.sampled),
                .image_format = info.format,
                .access_qualifier = info.access_qualifier,
            });
        },
        .sampler => try types.emit(self.gpa, .OpTypeSampler, result_id_operand),
        .sampled_image => try types.emit(self.gpa, .OpTypeSampledImage, .{
            .id_result = result_id,
            .image_type = self.typeId(ty.childType()),
        }),
        .array => {
            const info = ty.payload(.array);
            assert(info.length != 0);

            const size_type = Type.initTag(.u32);
            const size_type_id = try self.resolveTypeId(size_type);
            const length_id = self.allocId();
            try self.emitConstant(size_type_id, length_id, .{ .uint32 = info.length });

            try types.emit(self.gpa, .OpTypeArray, .{
                .id_result = result_id,
                .element_type = self.typeId(ty.childType()),
                .length = length_id,
            });
            if (info.array_stride != 0) {
                try self.decorate(ref_id, .{ .ArrayStride = .{ .array_stride = info.array_stride } });
            }
        },
        .runtime_array => {
            const info = ty.payload(.runtime_array);
            try types.emit(self.gpa, .OpTypeRuntimeArray, .{
                .id_result = result_id,
                .element_type = self.typeId(ty.childType()),
            });
            if (info.array_stride != 0) {
                try self.decorate(ref_id, .{ .ArrayStride = .{ .array_stride = info.array_stride } });
            }
        },
        .@"struct" => {
            const info = ty.payload(.@"struct");
            try types.emitRaw(self.gpa, .OpTypeStruct, 1 + info.members.len);
            types.writeOperand(IdResult, result_id);
            for (info.members) |member| {
                types.writeOperand(IdRef, self.typeId(member.ty));
            }
            try self.decorateStruct(ref_id, info);
        },
        .@"opaque" => try types.emit(self.gpa, .OpTypeOpaque, .{
            .id_result = result_id,
            .literal_string = ty.payload(.@"opaque").name,
        }),
        .pointer => {
            const info = ty.payload(.pointer);
            try types.emit(self.gpa, .OpTypePointer, .{
                .id_result = result_id,
                .storage_class = info.storage_class,
                .type = self.typeId(ty.childType()),
            });
            if (info.array_stride != 0) {
                try self.decorate(ref_id, .{ .ArrayStride = .{ .array_stride = info.array_stride } });
            }
            if (info.alignment) |alignment| {
                try self.decorate(ref_id, .{ .Alignment = .{ .alignment = alignment } });
            }
            if (info.max_byte_offset) |max_byte_offset| {
                try self.decorate(ref_id, .{ .MaxByteOffset = .{ .max_byte_offset = max_byte_offset } });
            }
        },
        .function => {
            const info = ty.payload(.function);
            try types.emitRaw(self.gpa, .OpTypeFunction, 2 + info.parameters.len);
            types.writeOperand(IdResult, result_id);
            types.writeOperand(IdRef, self.typeId(info.return_type));
            for (info.parameters) |parameter_type| {
                types.writeOperand(IdRef, self.typeId(parameter_type));
            }
        },
        .event => try types.emit(self.gpa, .OpTypeEvent, result_id_operand),
        .device_event => try types.emit(self.gpa, .OpTypeDeviceEvent, result_id_operand),
        .reserve_id => try types.emit(self.gpa, .OpTypeReserveId, result_id_operand),
        .queue => try types.emit(self.gpa, .OpTypeQueue, result_id_operand),
        .pipe => try types.emit(self.gpa, .OpTypePipe, .{
            .id_result = result_id,
            .qualifier = ty.payload(.pipe).qualifier,
        }),
        .pipe_storage => try types.emit(self.gpa, .OpTypePipeStorage, result_id_operand),
        .named_barrier => try types.emit(self.gpa, .OpTypeNamedBarrier, result_id_operand),
    }

    return result_id;
}

fn decorateStruct(self: *Module, target: IdRef, info: *const Type.Payload.Struct) !void {
    const debug_names = &self.sections.debug_names;

    if (info.name.len != 0) {
        try debug_names.emit(self.gpa, .OpName, .{
            .target = target,
            .name = info.name,
        });
    }

    // Decorations for the struct type itself.
    if (info.decorations.block)
        try self.decorate(target, .Block);
    if (info.decorations.buffer_block)
        try self.decorate(target, .BufferBlock);
    if (info.decorations.glsl_shared)
        try self.decorate(target, .GLSLShared);
    if (info.decorations.glsl_packed)
        try self.decorate(target, .GLSLPacked);
    if (info.decorations.c_packed)
        try self.decorate(target, .CPacked);

    // Decorations for the struct members.
    const extra = info.member_decoration_extra;
    var extra_i: u32 = 0;
    for (info.members, 0..) |member, i| {
        const d = member.decorations;
        const index = @intCast(Word, i);

        if (member.name.len != 0) {
            try debug_names.emit(self.gpa, .OpMemberName, .{
                .type = target,
                .member = index,
                .name = member.name,
            });
        }

        switch (member.offset) {
            .none => {},
            else => try self.decorateMember(
                target,
                index,
                .{ .Offset = .{ .byte_offset = @enumToInt(member.offset) } },
            ),
        }

        switch (d.matrix_layout) {
            .row_major => try self.decorateMember(target, index, .RowMajor),
            .col_major => try self.decorateMember(target, index, .ColMajor),
            .none => {},
        }
        if (d.matrix_layout != .none) {
            try self.decorateMember(target, index, .{
                .MatrixStride = .{ .matrix_stride = extra[extra_i] },
            });
            extra_i += 1;
        }

        if (d.no_perspective)
            try self.decorateMember(target, index, .NoPerspective);
        if (d.flat)
            try self.decorateMember(target, index, .Flat);
        if (d.patch)
            try self.decorateMember(target, index, .Patch);
        if (d.centroid)
            try self.decorateMember(target, index, .Centroid);
        if (d.sample)
            try self.decorateMember(target, index, .Sample);
        if (d.invariant)
            try self.decorateMember(target, index, .Invariant);
        if (d.@"volatile")
            try self.decorateMember(target, index, .Volatile);
        if (d.coherent)
            try self.decorateMember(target, index, .Coherent);
        if (d.non_writable)
            try self.decorateMember(target, index, .NonWritable);
        if (d.non_readable)
            try self.decorateMember(target, index, .NonReadable);

        if (d.builtin) {
            try self.decorateMember(target, index, .{
                .BuiltIn = .{ .built_in = @intToEnum(spec.BuiltIn, extra[extra_i]) },
            });
            extra_i += 1;
        }
        if (d.stream) {
            try self.decorateMember(target, index, .{
                .Stream = .{ .stream_number = extra[extra_i] },
            });
            extra_i += 1;
        }
        if (d.location) {
            try self.decorateMember(target, index, .{
                .Location = .{ .location = extra[extra_i] },
            });
            extra_i += 1;
        }
        if (d.component) {
            try self.decorateMember(target, index, .{
                .Component = .{ .component = extra[extra_i] },
            });
            extra_i += 1;
        }
        if (d.xfb_buffer) {
            try self.decorateMember(target, index, .{
                .XfbBuffer = .{ .xfb_buffer_number = extra[extra_i] },
            });
            extra_i += 1;
        }
        if (d.xfb_stride) {
            try self.decorateMember(target, index, .{
                .XfbStride = .{ .xfb_stride = extra[extra_i] },
            });
            extra_i += 1;
        }
        if (d.user_semantic) {
            const len = extra[extra_i];
            extra_i += 1;
            const semantic = @ptrCast([*]const u8, &extra[extra_i])[0..len];
            try self.decorateMember(target, index, .{
                .UserSemantic = .{ .semantic = semantic },
            });
            extra_i += std.math.divCeil(u32, extra_i, @sizeOf(u32)) catch unreachable;
        }
    }
}

pub fn simpleStructType(self: *Module, members: []const Type.Payload.Struct.Member) !Type.Ref {
    const payload = try self.arena.create(Type.Payload.Struct);
    payload.* = .{
        .members = try self.arena.dupe(Type.Payload.Struct.Member, members),
        .decorations = .{},
    };
    return try self.resolveType(Type.initPayload(&payload.base));
}

pub fn arrayType(self: *Module, len: u32, ty: Type.Ref) !Type.Ref {
    const payload = try self.arena.create(Type.Payload.Array);
    payload.* = .{
        .element_type = ty,
        .length = len,
    };
    return try self.resolveType(Type.initPayload(&payload.base));
}

pub fn ptrType(
    self: *Module,
    child: Type.Ref,
    storage_class: spec.StorageClass,
    alignment: ?u32,
) !Type.Ref {
    const ptr_payload = try self.arena.create(Type.Payload.Pointer);
    ptr_payload.* = .{
        .storage_class = storage_class,
        .child_type = child,
        .alignment = alignment,
    };
    return try self.resolveType(Type.initPayload(&ptr_payload.base));
}

pub fn changePtrStorageClass(self: *Module, ptr_ty_ref: Type.Ref, new_storage_class: spec.StorageClass) !Type.Ref {
    const payload = try self.arena.create(Type.Payload.Pointer);
    payload.* = self.typeRefType(ptr_ty_ref).payload(.pointer).*;
    payload.storage_class = new_storage_class;
    return try self.resolveType(Type.initPayload(&payload.base));
}

pub fn emitConstant(
    self: *Module,
    ty_id: IdRef,
    result_id: IdRef,
    value: spec.LiteralContextDependentNumber,
) !void {
    try self.sections.types_globals_constants.emit(self.gpa, .OpConstant, .{
        .id_result_type = ty_id,
        .id_result = result_id,
        .value = value,
    });
}

/// Decorate a result-id.
pub fn decorate(
    self: *Module,
    target: IdRef,
    decoration: spec.Decoration.Extended,
) !void {
    try self.sections.annotations.emit(self.gpa, .OpDecorate, .{
        .target = target,
        .decoration = decoration,
    });
}

/// Decorate a result-id which is a member of some struct.
pub fn decorateMember(
    self: *Module,
    structure_type: IdRef,
    member: u32,
    decoration: spec.Decoration.Extended,
) !void {
    try self.sections.annotations.emit(self.gpa, .OpMemberDecorate, .{
        .structure_type = structure_type,
        .member = member,
        .decoration = decoration,
    });
}

pub fn allocGlobal(self: *Module) !Global.Index {
    try self.globals.nodes.append(self.gpa, .{
        .result_id = self.allocId(),
        .begin_inst = undefined,
        .end_inst = undefined,
        .begin_dep = undefined,
            .end_dep = undefined,
    });
    return @intToEnum(Global.Index, @intCast(u32, self.globals.nodes.items.len - 1));
}

pub fn globalPtr(self: *Module, index: Global.Index) *Global {
    return &self.globals.nodes.items[@enumToInt(index)];
}

/// Begin generating the global for `index`. The previous global is finalized
/// at this point, and the global for `index` is made active. Any new calls to
/// `addGlobalDependency` will affect this global. After a new call to this function,
/// the prior active global cannot be modified again.
pub fn beginGlobal(self: *Module, index: Global.Index) IdRef {
    const global = self.globalPtr(index);
    global.begin_inst = @intCast(u32, self.globals.section.instructions.items.len);
    global.begin_dep = @intCast(u32, self.globals.dependencies.items.len);
    self.globals.current_global = index;
    return global.result_id;
}

/// Finalize the global. After this point, the current global cannot be modified anymore.
pub fn endGlobal(self: *Module) void {
    const global = self.globalPtr(self.globals.current_global.?);
    global.end_inst = @intCast(u32, self.globals.section.instructions.items.len);
    global.end_dep = @intCast(u32, self.globals.dependencies.items.len);
    self.globals.current_global = null;
}

pub fn addGlobalDependency(self: *Module, dependency: Global.Index) !void {
    assert(self.globals.current_global != null);
    assert(self.globals.current_global.? != dependency);
    try self.globals.dependencies.append(self.gpa, dependency);
}
