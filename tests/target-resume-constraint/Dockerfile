FROM pgcopydb

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh
COPY ./import.sql import.sql

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
