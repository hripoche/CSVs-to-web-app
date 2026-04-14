using Genie, Genie.Router, Genie.Renderer.Html, Genie.Requests
using DataFrames
using CSV
using JSON
using SQLite

# Initialize the Dict to store DataFrames
const dataframes = Dict{String, DataFrame}()

# Database file path
const DB_PATH = "dataframes.sqlite"

# NOT USED YET
const UPLOAD_PATH = join(@__DIR__,"public","upload")

const JOINS = [Dict{:SOURCE => "file1_csv", :TARGET => "Strain_csv", :SOURCE_COL => "Strain", :TARGET_COL => "Strain"},
               Dict{:SOURCE => "file1_csv", :TARGET => "Vector_csv", :SOURCE_COL => "Vector", :TARGET_COL => "Vector"}]

# Helper function to convert filename to a valid SQL table name
function filename_to_table_name(filename::AbstractString)
    return replace(filename, r"[^\w]" => "_")
end

function get_table_names(db::SQLite.DB)::Array{String}
    result = []
    df_tables = SQLite.tables(db) |> DataFrame
    for row in eachrow(df_tables[!,:name])
        append!(result,row)
    end
    return result
end

# Load existing DataFrames from the database at startup
function load_dataframes()
    if isfile(DB_PATH)
        db = SQLite.DB(DB_PATH)
        table_names = get_table_names(db)
        println(table_names)
        for name in table_names
            println("table : $name")
            #println(dump(DBInterface.execute(db, "SELECT * FROM $name")))
            #df = DBInterface.execute(db, "SELECT * FROM $name") |> DataFrame
            df = DBInterface.execute(db, "SELECT * FROM $name") |> DataFrame
            #println(df)
            dataframes[name] = df
        end
        SQLite.close(db)
    end
end

# Save a DataFrame to the SQLite database
function save_dataframe_to_db(name::String, df::DataFrame)
    println(name)
    println(names(df))
    db = SQLite.DB(DB_PATH)
    println(db)
    try
        #SQLite.load!(df, db, name, ifnotexists=true, replace=true, onconflict="ROLLBACK")
        SQLite.load!(df, db, name, ifnotexists=true, replace=true)
        #df |> SQLite.Query(db, name)
    finally
        SQLite.close(db)
    end
end

function save_all_dataframes_to_db(dict::Dict{String,DataFrame})
    for name in keys(dict)
        df = dict[name]
        name = filename_to_table_name(name)
        save_dataframe_to_db(name,df)
    end
end

# Delete a DataFrame from the SQLite database
function delete_dataframe_from_db(name::String)
    db = SQLite.DB(DB_PATH)
    try
        DBInterface.execute(db, "DROP TABLE IF EXISTS $name")
    finally
        SQLite.close(db)
    end
end

# Load DataFrames at startup
load_dataframes()

"""
# Escape HTML characters to prevent injection attacks
function escape_html(str::String)
    return replace(str, html_escape_table)
end

const html_escape_table = Dict(
    '&' => "&amp;",
    '<' => "&lt;",
    '>' => "&gt;",
    '"' => "&quot;",
    '\'' => "&#x27;",
    '/' => "&#x2F;"
)
"""

# Route to display the home page with the list of DataFrames
route("/") do
    output = """
    <h1>DataFrames</h1>
    <ul>
    """
    for name in keys(dataframes)
        output *= "<li><a href=\"/dataframe/$name\">$name</a></li>"
    end
    output *= """
    </ul>
    <a href="/upload">Upload CSV File</a>
    """
    html(output)
end

# Route to display the upload form
route("/upload") do
    html("""
    <h1>Upload CSV File</h1>
    <form action="/upload" method="post" enctype="multipart/form-data">
        <input type="file" name="csvfile" accept=".csv" required>
        <input type="submit" value="Upload">
    </form>
    <a href="/">Back to List</a>
    """)
end

# Route to handle the uploaded CSV file using filespayload()
route("/upload", method=POST) do
    files = filespayload()
    if infilespayload(:csvfile)
        write(filespayload(:csvfile))
        stat(filename(filespayload(:csvfile)))
        fname = filename(filespayload(:csvfile))
        println(fname)
        df = CSV.read(fname,DataFrame,header=true)
        tname = filename_to_table_name(fname)
        println("tname : $tname")
        mv(fname,tname,force=true)
        println(tname)
        dataframes[tname] = df
        save_dataframe_to_db(tname, df)
        redirect("/")
    else
        html("No file uploaded.")
    end
end

# Route to display a specific DataFrame
route("/dataframe/:name") do
    name = "$(payload(:name))"
    if !haskey(dataframes, name)
        return html("DataFrame '$name' not found.")
    end
    df = dataframes[name]
    output = render_dataframe(name, df)
    html(output)
end

# Helper function to render a DataFrame as HTML
function render_dataframe(name::String, df::DataFrame)
    output = """
    <h1>DataFrame: $name</h1>
    <table border="1">
        <tr>
    """
    # Header
    for col in names(df)
        output *= "<th>$col</th>"
    end
    output *= "<th>Actions</th></tr>"
    # Rows
    for (i, row) in enumerate(eachrow(df))
        output *= "<tr>"
        for val in row
            output *= "<td>$val</td>"
        end
        output *= """
        <td>
            <a href="/dataframe/$name/edit/$i">Edit</a> |
            <a href="/dataframe/$name/delete/$i" onclick="return confirm('Are you sure?')">Delete</a>
        </td>
        </tr>
        """
    end
    output *= """
    </table>
    <a href="/dataframe/$name/add">Add Row</a><br>
    <a href="/dataframe/$name/export">Export to JSON</a><br>
    <form action="/dataframe/$name/delete" method="post" onsubmit="return confirm('Are you sure you want to delete this DataFrame?')">
        <input type="submit" value="Delete DataFrame">
    </form>
    <a href="/">Back to List</a>
    """
    return output
end

# Route to edit a row in a DataFrame (GET)
route("/dataframe/:name/edit/:row", method=GET) do
    name = "$(payload(:name))"
    row = "$(payload(:row))"
    row_index = parse(Int, row)
    if !haskey(dataframes, name)
        return html("DataFrame '$name' not found.")
    end
    df = dataframes[name]
    if row_index < 1 || row_index > nrow(df)
        return html("Invalid row index.")
    end
    row = df[row_index, :]
    ### HACK !!!
    if length(JOINS) > 0
        for d in JOINS
            if (name == d[:SOURCE] && haskey(dataframes,d[:TARGET]))
                output = render_edit_form_with_select(d[:SOURCE], row_index, df, row, dataframes[d[:TARGET]], d[:SOURCE_COL], d[:TARGET_COL])    
            end
        end
    else 
        output = render_edit_form(name, row_index, df, row)
    end
    html(output)
end

# Helper function to render the edit form
function render_edit_form(name::String, row_index::Int, df::DataFrame, row)
    output = """
    <h1>Edit Row $row_index in $name</h1>
    <form action="/dataframe/$name/edit/$row_index" method="post">
    """
    for col in names(df)
        val = row[col]
        output *= """
        <label>$col:</label>
        <input type="text" name="$col" value="$(string(val))" required><br>
        """
    end
    output *= """
    <input type="submit" value="Save">
    </form>
    <a href="/dataframe/$name">Back to DataFrame</a>
    """
    return output
end

# Helper function to render the edit form
function render_edit_form_with_select(name::String, row_index::Int, df_source::DataFrame, row, df_target::DataFrame, source_col::String, target_col::String)
    output = """
    <h1>Edit Row $row_index in $name</h1>
    <form action="/dataframe/$name/edit/$row_index" method="post">
    """
    for col in names(df_source)
        if col == source_col ### HACK !!!
            vals = df_target[!,target_col]
            output *= """
            <label>$col:</label>
            <select name="$col" id="$col">
            """
            for val in vals
                output *= """<option value="$(string(val))" $(haskey(row,col) && string(val) == string(row[col]) ? " selected" : "")>$(string(val))</option>"""
            end
            output *= """</select><br>"""
        else
            val = row[col]
            output *= """
            <label>$col:</label>
            <input type="text" name="$col" value="$(string(val))" required><br>
            """    
        end
    end
    output *= """
    <input type="submit" value="Save">
    </form>
    <a href="/dataframe/$name">Back to DataFrame</a>
    """
    return output
end

# Route to handle the row edit (POST)
route("/dataframe/:name/edit/:row", method=POST) do
    name = "$(payload(:name))"
    row = "$(payload(:row))"
    row_index = parse(Int, row)
    if !haskey(dataframes, name)
        return html("DataFrame '$name' not found.")
    end
    df = dataframes[name]
    # Update the row with new values
    for col in names(df)
        #val = Genie.Requests.params(Symbol(col)) !!!
        val = "$(payload(Symbol(col)))"
        println("val : $val")
        println("type : $(typeof(val))")
        try
            #df[row_index, col] = parse(typeof(df[!, col]), val)
            col_type = eltype(df[!, col])
            if col_type == String
                df[row_index, col] = val
            else
                df[row_index, col] = parse(col_type, val)
            end
        catch e
            return html("Invalid input for column '$col': $e")
        end
    end
    dataframes[name] = df
    save_dataframe_to_db(name, df)
    redirect("/dataframe/$name")
end

# Route to delete a row from a DataFrame
route("/dataframe/:name/delete/:row", method=GET) do
    name = "$(payload(:name))"
    row = "$(payload(:row))"
    row_index = parse(Int, row)
    if !haskey(dataframes, name)
        return html("DataFrame '$name' not found.")
    end
    df = dataframes[name]
    if row_index < 1 || row_index > nrow(df)
        return html("Invalid row index.")
    end
    # Delete the row
    delete!(df, row_index)
    dataframes[name] = df
    save_dataframe_to_db(name, df)
    redirect("/dataframe/$name")
end

# Route to add a new row to a DataFrame (GET)
route("/dataframe/:name/add", method=GET) do
    name = "$(payload(:name))"
    if !haskey(dataframes, name)
        return html("DataFrame '$name' not found.")
    end
    df = dataframes[name]
    #output = render_add_form(name, df)
    ### HACK !!!
    if name == MAIN_TABLE && haskey(dataframes,STRAIN_TABLE) 
        output = render_add_form_with_select(name, df, dataframes[STRAIN_TABLE], JOIN)
    else 
        output = render_add_form(name, df)
    end
    html(output)
end

# Helper function to render the add row form
function render_add_form(name::String, df::DataFrame)
    output = """
    <h1>Add Row to $name</h1>
    <form action="/dataframe/$name/add" method="post">
    """
    for col in names(df)
        output *= """
        <label>$col:</label>
        <input type="text" name="$col" required><br>
        """
    end
    output *= """
    <input type="submit" value="Add">
    </form>
    <a href="/dataframe/$name">Back to DataFrame</a>
    """
    return output
end

# Helper function to render the add row form
function render_add_form_with_select(name::String, df::DataFrame, df_strain::DataFrame, join::String)
    output = """
    <h1>Add Row to $name</h1>
    <form action="/dataframe/$name/add" method="post">
    """
    for col in names(df)
        if col == join ### HACK !!!
            vals = df_strain[!,join]
            output *= """
            <label>$col:</label>
            <select name="$col" id="$col">
            """
            for val in vals
                output *= """<option value="$(string(val))">$(string(val))</option>"""
            end
            output *= """</select><br>"""
        else    
            output *= """
            <label>$col:</label>
            <input type="text" name="$col" required><br>
            """
        end
    end
    output *= """
    <input type="submit" value="Add">
    </form>
    <a href="/dataframe/$name">Back to DataFrame</a>
    """
    return output
end

# Route to handle adding a new row (POST)
route("/dataframe/:name/add", method=POST) do
    name = "$(payload(:name))"
    if !haskey(dataframes, name)
        return html("DataFrame '$name' not found.")
    end
    df = dataframes[name]
    new_row = DataFrame()
    # Collect the new row data
    for col in names(df)
        #val = Genie.Requests.params(Symbol(col))
        val = "$(payload(Symbol(col)))"
        println("type : val : $(typeof(val))")
        try
            col_type = eltype(df[!, col])
            println("typeof : $(typeof(col_type))")
            if col_type == String
                val_parsed = val
            else
                val_parsed = parse(col_type, val)
            end
            new_row[!, col] = [val_parsed]
        catch e
            #return html("Invalid input for column '$col': $(e.msg)")
            return html("Invalid input for column '$col': $e")
        end
    end
    # Append the new row
    append!(df, new_row)
    dataframes[name] = df
    save_dataframe_to_db(name, df)
    redirect("/dataframe/$name")
end

# Route to export a DataFrame to JSON
route("/dataframe/:name/export") do
    name = "$(payload(:name))"
    if !haskey(dataframes, name)
        return html("DataFrame '$name' not found.")
    end
    df = dataframes[name]
    #content_type!("application/json")
    output = """
    <pre>
    $(JSON.json(df))
    </pre>
    """
    html(output)
end

# Route to save a DataFrame to an SQL table (this now updates the existing table)
route("/dataframe/:name/save", method=POST) do
    name = "$(payload(:name))"
    if !haskey(dataframes, name)
        return html("DataFrame '$name' not found.")
    end
    df = dataframes[name]
    save_dataframe_to_db(name, df)
    html("DataFrame '$name' saved to SQL table.")
end

# Route to delete a DataFrame entirely
route("/dataframe/:name/delete", method=POST) do
    name = "$(payload(:name))"
    if haskey(dataframes, name)
        delete!(dataframes, name)
        delete_dataframe_from_db(name)
        redirect("/")
    else
        html("DataFrame '$name' not found.")
    end
end

# Start the Genie application
Genie.config.run_as_server = true
up()
